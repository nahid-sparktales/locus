import AppKit
import Combine
import Foundation
import PDFKit
import QuartzCore
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var agentRuntimePhase: RuntimePhase = .starting("Starting the local agent…")
    @Published var modelRuntimePhase: RuntimePhase = .starting("Checking the model provider…")
    var isAgentOnline: Bool { agentRuntimePhase.isOnline }
    var isModelOnline: Bool { modelRuntimePhase.isOnline }
    @Published var models: [ModelInfo] = []
    /// The local Ollama models, kept separately because `models` reflects
    /// whichever provider the agent is currently pointed at — with an account
    /// active it holds that account's list, not the local one.
    @Published private(set) var localModels: [ModelInfo] = []
    @Published private(set) var providerAccounts: [ProviderAccount] = []
    @Published private(set) var accountModels: [UUID: [String]] = [:]
    @Published private(set) var accountStatus: [UUID: ProviderAccountStatus] = [:]
    @Published var sessions: [SessionSummary] = []
    @Published var currentSessionID = ""
    @Published var sessionInfo: SessionInfo?
    @Published var blocks: [ChatBlock] = []
    @Published var todos: [TodoItem] = []
    @Published var isBusy = false
    /// A short, truthful description of where an in-flight steering request
    /// is waiting. It is cleared when the direction joins the active turn.
    @Published private(set) var steeringState: String?
    @Published var selectedMode: WorkMode = .work {
        didSet {
            // Changing modes is taking a stance on what happens next, so a
            // pending "implement this plan?" prompt would only contradict it.
            if selectedMode != oldValue { planApprovalPending = false }
            if selectedMode != .ask { lastAgenticMode = selectedMode }
            // Just Chat is deliberately not a workspace surface. Remember the
            // inspector's prior state so leaving Chat restores exactly what
            // the user had before, regardless of which mode control they use.
            if selectedMode == .ask, oldValue != .ask {
                restoreInspectorAfterJustChat = !inspectorCollapsed
                inspectorCollapsed = true
            } else if selectedMode != .ask, oldValue == .ask {
                let shouldRestoreInspector = restoreInspectorAfterJustChat
                restoreInspectorAfterJustChat = false
                if shouldRestoreInspector { inspectorCollapsed = false }
            }
            scheduleWorkspacePersistence()
        }
    }
    /// Only `selectInspectorTab(_:)` may change this. Backend events set a
    /// badge instead, so a run can never yank the panel out from under you.
    @Published private(set) var inspectorTab: InspectorTab = .plan
    @Published var inspectorCollapsed = true {
        didSet {
            guard inspectorCollapsed != oldValue else { return }
            settings.inspectorCollapsed = inspectorCollapsed
        }
    }
    @Published private(set) var inspectorWidth: CGFloat = CGFloat(AppSettings.defaultInspectorWidth)
    @Published private(set) var planHasUnseenUpdate = false
    /// True between a completed Plan-mode turn that produced a plan and the
    /// user's answer to "implement this plan?". While set, the composer input
    /// is replaced by PlanApprovalPromptView, the way permission requests are.
    @Published private(set) var planApprovalPending = false
    @Published private(set) var activePlan: PlanDocument?
    @Published private(set) var gitChanges: [GitChange] = []
    @Published private(set) var isRefreshingGitStatus = false
    @Published private(set) var isGitRepository = false
    @Published private(set) var lastGitRefreshFailed = false
    @Published var commitMessage = ""
    @Published private(set) var isPerformingGitAction = false
    @Published private(set) var isDraftingCommitMessage = false
    @Published var pendingDiscard: GitChange?
    @Published private(set) var changesHaveUnseenUpdate = false
    @Published private(set) var selectedChangePath: String?
    @Published private(set) var selectedChangeDiff: String?
    @Published var fileQuery = ""
    @Published private(set) var previewedFilePath: String?
    @Published private(set) var previewedFileContents: String?
    @Published private(set) var agentInstructionsExists = false
    @Published var agentInstructionsDraft = ""
    @Published private(set) var savedAgentInstructions = ""
    @Published private(set) var agentInstructionsError: String?
    @Published private(set) var isLoadingAgentInstructions = false
    @Published private(set) var isSavingAgentInstructions = false
    @Published var contextFiles: [ContextFile] = []
    @Published var chatAttachments: [ChatAttachment] = []
    @Published var chatAttachmentNotice: String?
    @Published var isLoadingChatAttachments = false
    @Published var checkpoints: [SessionCheckpoint] = []
    @Published var workspaceProfiles: [WorkspaceProfile] = []
    @Published var draftText = "" {
        didSet {
            resetHistoryCursorIfEdited()
            scheduleWorkspacePersistence()
        }
    }
    @Published var promptHistory: [String] = []
    @Published var queuedMessages: [String] = []
    @Published var shortcutsPresented = false
    @Published var sidebarCollapsed = false {
        didSet {
            guard sidebarCollapsed != oldValue else { return }
            settings.sidebarCollapsed = sidebarCollapsed
        }
    }
    @Published var workspaceFileIndex: [URL] = []
    @Published var gitBranch: String?
    @Published var settings: AppSettings {
        didSet {
            scheduleWorkspacePersistence()
            // Without this, anything a view writes into `settings` is lost on
            // relaunch: the only other writer is applySettings(), so the
            // preview URL — and now the inspector chrome — never persisted.
            scheduleSettingsPersistence()
        }
    }
    @Published var settingsPresented = false
    @Published var settingsPage: SettingsPage = .general
    @Published var modelLibraryPresented = false
    @Published var commandPalettePresented = false
    @Published var checkpointPresented = false
    @Published var clearChatConfirmationPresented = false
    @Published var clearSessionsConfirmationPresented = false
    @Published var isClearingSessions = false
    @Published var showArchivedSessions = false
    @Published var searchQuery = ""
    @Published var expandedWorkspaceIDs: Set<String> = []
    @Published var transcriptSearchPresented = false
    @Published var transcriptSearchQuery = "" {
        didSet { transcriptSearchSelection = 0 }
    }
    @Published var transcriptSearchSelection = 0
    @Published var previewReloadID = UUID()
    @Published var streamRevision = 0
    @Published var toast: AppToast?
    var toastMessage: String? { toast?.message }
    @Published var backendLogHint = ""
    @Published var contextNotice: String?
    @Published var isLoadingContext = false
    @Published private(set) var extensions = ExtensionsResponse.empty
    @Published private(set) var extensionCatalog: [ExtensionCatalogEntry] = []
    @Published private(set) var extensionTools: [ExtensionToolMetadata] = []
    @Published var extensionErrorMessage: String?
    @Published private(set) var isLoadingExtensions = false
    /// Console state. A `let` on its own ObservableObject, not @Published
    /// here: republishing AppModel on every output chunk would redraw the
    /// sidebar, conversation and composer at the command's output rate.
    let terminal = TerminalSession()
    let computerControl = ComputerControlService()
    let streamingReply = StreamingReplyState()

    private let backend: BackendService
    private let backendProcess = BackendProcess()
    private let ollamaRuntime = OllamaRuntime()
    private let mcpAuthCoordinator = MCPAuthCoordinator()
    private let workspaceAccess: WorkspaceAccess
    private var initialWorkspacePath: String?
    private var streamingAssistantID: UUID?
    private var pendingTokens = ""
    private var pendingReasoning = ""
    /// Rough size of the reply streamed since the last `session_info`, so the
    /// context meter moves during a turn instead of freezing at the pre-turn
    /// value. Reset whenever the backend supplies a real count.
    private var streamedCharsThisTurn = 0
    private lazy var streamFlushDriver = DisplaySynchronizedFlushDriver { [weak self] in
        self?.flushPendingTokens()
    }
    private var refreshTask: Task<Void, Never>?
    private var runtimeRecoveryTask: Task<Void, Never>?
    private var runtimeRecoveryAttempt = 0
    private var extensionRefreshTask: Task<Void, Never>?
    private var restoredTranscriptContext: String?
    private var toastTask: Task<Void, Never>?
    private var pendingDeletedChat: DeletedChatUndo?
    private var profilePersistenceTask: Task<Void, Never>?
    private var settingsPersistenceTask: Task<Void, Never>?
    private var promptHistoryCursor: Int?
    private var stashedDraft: String?
    private var pendingSessionReset = false
    /// Whether the turn in flight rewrote the todo list. The approval prompt
    /// is offered only for turns that actually produced a plan — a Plan-mode
    /// chat answer must not re-offer a plan left over from an earlier run.
    private var planTodosChangedThisTurn = false
    private var planReadyThisTurn = false
    /// What the user actually dispatched, kept separate from the live picker
    /// so a mid-run mode change cannot relabel the completion marker or alter
    /// plan reconciliation.
    var turnDispatchedMode: WorkMode?
    /// Client-side fallback for agents from before `turn_done.duration_ms`.
    private var turnStartedAt: Date?
    /// Turning Just Chat off returns to the last mode that could act on the
    /// workspace instead of always making the user reselect Build or Plan.
    private var lastAgenticMode: WorkMode = .work
    /// Just Chat temporarily hides the inspector. This records whether it was
    /// visible so Work mode can restore the user's layout on exit.
    private var restoreInspectorAfterJustChat = false
    /// Whether the turn in flight was dispatched in Plan mode. The approval
    /// offer is keyed to this latch, not the live picker — switching modes
    /// while a Build run streams must not turn that run's todo bookkeeping
    /// into an "implement this plan?" offer. Internal so tests can dispatch
    /// turns without a live backend.
    var turnDispatchedInPlanMode = false
    private var pendingRetry = false
    /// Stop & Send is deliberately not part of the ordinary queue: it must
    /// wait for the interrupted turn's terminal event before it can create a
    /// fresh provider turn and conversation-history boundary.
    private var pendingStopAndSend: String?
    private var pendingCheckpointRestore: SessionCheckpoint?
    private var pendingRewindDraft: String?
    private var pendingWorkspacePath: String?
    private var workspaceToOpenAfterReconnect: String?
    private var appliedWorkspacePath: String?
    private var sessionResetWatchdog: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var gitStatusTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var commitDraftTask: Task<Void, Never>?
    private var filePreviewTask: Task<Void, Never>?
    private var agentInstructionsTask: Task<Void, Never>?
    private var indexedWorkspacePath: String?
    private var terminationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// False for unit and UI tests. Views check it before touching the
    /// credential file: a test must not read — or delete — the secrets of
    /// whoever is running the suite.
    let persistenceEnabled: Bool
    private let isUITesting: Bool
    private var isShuttingDown = false

    init(startImmediately: Bool = true) {
        let isUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"
        self.isUITesting = isUITesting
        persistenceEnabled = startImmediately && !isUITesting
        let defaults = UserDefaults.standard
        var loadedSettings: AppSettings
        // Gated on `persistenceEnabled` for the same reason the accounts below
        // are: a model that will never write must not read either. Without it a
        // unit test inherited whatever the developer had saved in the real app —
        // an active account, a configured proxy — so the suite passed or failed
        // according to the machine it ran on rather than the code under test.
        if !isUITesting, persistenceEnabled,
           let data = defaults.data(forKey: "Locus.settings"),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            loadedSettings = saved
        } else {
            loadedSettings = AppSettings()
        }

        // `persistenceEnabled` is false only for tests and UI testing, and a
        // model that will never write must not read either: loading here meant a
        // unit test started with whatever accounts the developer happened to have
        // saved, so account tests passed on CI and failed on a real machine —
        // counting two accounts that belonged to the person running the suite.
        if !isUITesting, persistenceEnabled {
            var accounts = ProviderAccountStore.load(from: defaults)
            var routingRewritten = false
            // The pre-accounts remote endpoint becomes a Custom account, so an
            // upgrade keeps working without re-entering the key.
            if let migrated = ProviderAccountStore.migrateLegacyEndpoint(
                settings: loadedSettings,
                existing: accounts
            ) {
                accounts = [migrated]
                // Only a real launch commits it: a unit test constructing an
                // AppModel must not rewrite the user's stored accounts.
                if persistenceEnabled {
                    ProviderAccountStore.save(accounts, to: defaults)
                }
                if loadedSettings.provider == .remote {
                    loadedSettings.activeAccountID = migrated.id.uuidString
                }
                loadedSettings.remoteBaseURL = ""
                loadedSettings.remoteModel = ""
                routingRewritten = true
            }
            // An account can be deleted while the app is closed; never boot
            // into a remote provider that no longer has credentials.
            if let id = loadedSettings.activeAccountID,
               !accounts.contains(where: { $0.id.uuidString == id })
            {
                loadedSettings.activeAccountID = nil
                loadedSettings.provider = .ollama
                routingRewritten = true
            }
            providerAccounts = accounts
            // A key whose account is gone is residue from a crash between the
            // two writes; nothing can reach it again.
            //
            // Only ever swept on a *complete* read. The decode above salvages
            // what it can, and the accounts it could not parse are exactly the
            // ones whose keys would look orphaned — deleting those would turn a
            // recoverable parse failure into permanent credential loss, and
            // Anthropic and the Kimi Code console each show a key once. The
            // same guard covers an empty read. Note the credential file now
            // lives beside UserDefaults rather than in the keychain, so a
            // container reset takes both — the guard no longer protects against
            // that, only against a lossy decode.
            if persistenceEnabled,
               let stored = ProviderAccountStore.storedCount(in: defaults),
               stored == accounts.count
            {
                CredentialStore.removeOrphanedProviderKeys(
                    keeping: Set(accounts.map(\.keychainAccount))
                )
            }
            // Written here rather than through `settings`: assignments inside
            // init skip property observers, so the debounced save never fires
            // and the migration would be redone — with a *new* account id —
            // on every launch.
            if routingRewritten, persistenceEnabled,
               let data = try? JSONEncoder().encode(loadedSettings)
            {
                defaults.set(data, forKey: "Locus.settings")
            }
        }
        let migrateLegacyBuildMode = !loadedSettings.adaptiveWorkMigrationCompleted
        loadedSettings.adaptiveWorkMigrationCompleted = true
        if migrateLegacyBuildMode, persistenceEnabled,
           let data = try? JSONEncoder().encode(loadedSettings)
        {
            defaults.set(data, forKey: "Locus.settings")
        }
        settings = loadedSettings
        // The proxy snapshot is what static call sites read; seed it before
        // anything can make a request. A test model must not read the
        // credential file, for the same reason it must not read accounts.
        ProxyRuntime.shared.update(
            settings: loadedSettings,
            password: persistenceEnabled ? CredentialStore.proxyPassword() : nil
        )

        if !isUITesting,
           let data = defaults.data(forKey: "Locus.checkpoints"),
           let saved = try? JSONDecoder().decode([SessionCheckpoint].self, from: data)
        {
            checkpoints = saved
        }
        var restoredWorkspacePaths: [String] = []
        if !isUITesting,
           let data = defaults.data(forKey: "Locus.workspaceProfiles"),
           let saved = try? JSONDecoder().decode([WorkspaceProfile].self, from: data)
        {
            var recent = saved.sorted { $0.lastOpened > $1.lastOpened }
            if migrateLegacyBuildMode {
                recent = Self.migrateLegacyBuildProfiles(recent)
                if persistenceEnabled,
                   let migratedData = try? JSONEncoder().encode(recent)
                {
                    defaults.set(migratedData, forKey: "Locus.workspaceProfiles")
                }
            }
            workspaceProfiles = recent
            restoredWorkspacePaths = recent.map(\.path)
        }
        if !isUITesting, persistenceEnabled {
            expandedWorkspaceIDs = Set(
                defaults.stringArray(forKey: "Locus.expandedWorkspaces") ?? []
            )
        }
        let access = WorkspaceAccess(defaults: defaults)
        workspaceAccess = access
        initialWorkspacePath = access.restoreAvailable(paths: restoredWorkspacePaths)
            ?? WorkspaceAccess.sandboxWorkspaceURL()?.path
        promptHistory = isUITesting ? [] : (defaults.stringArray(forKey: "Locus.promptHistory") ?? [])

        // Seeded here rather than in a didSet: assignments inside init skip
        // property observers, so this cannot echo back into persistence.
        inspectorWidth = CGFloat(loadedSettings.inspectorWidth)
        inspectorCollapsed = loadedSettings.inspectorCollapsed
        sidebarCollapsed = loadedSettings.sidebarCollapsed
        inspectorTab = loadedSettings.resolvedInspectorTab

        backend = BackendService(
            baseURL: URL(string: loadedSettings.backendURL) ?? URL(string: "http://127.0.0.1:8791")!
        )

        backend.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.agentRuntimePhase = .online
                    self.runtimeRecoveryAttempt = 0
                    self.sendComputerControlCapability()
                } else if self.agentRuntimePhase.isOnline, !self.isShuttingDown {
                    self.agentRuntimePhase = .recovering("Reconnecting to the local agent…")
                    self.recoverFromLostConnection()
                    self.scheduleRuntimeRecovery(reason: "The local agent connection was lost.")
                }
            }
        }
        backend.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        terminal.transport = self

        backendProcess.onUnexpectedExit = { [weak self] code, output in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.recoverFromLostConnection()
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.backendLogHint = detail.isEmpty
                    ? "The local agent exited with status \(code)."
                    : String(detail.suffix(1_000))
                self.agentRuntimePhase = .recovering("Restarting the local agent…")
                self.scheduleRuntimeRecovery(reason: "The local agent stopped unexpectedly.")
            }
        }

        if isUITesting {
            seedUITestState()
        } else if startImmediately {
            // Shutdown must not depend on any window still existing at quit
            // time, so the terminate hook lives on the model, not a view.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shutdown()
                }
            }
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          !self.agentRuntimePhase.isOnline || !self.modelRuntimePhase.isOnline
                    else { return }
                    self.scheduleRuntimeRecovery(
                        reason: "Checking local services after Locus became active.",
                        immediate: true
                    )
                }
            }
            Task { await bootstrap() }
        }
    }

    var workspacePath: String {
        if let cwd = sessionInfo?.cwd, !cwd.isEmpty {
            return cwd
        }
        return initialWorkspacePath ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var selectedModel: String {
        sessionInfo?.model ?? models.first?.name ?? "No model"
    }

    /// The provider account the agent is pointed at, or nil for local Ollama.
    var activeAccount: ProviderAccount? {
        guard let id = settings.activeAccountID else { return nil }
        return providerAccounts.first { $0.id.uuidString == id }
    }

    /// The local runtime's address. `sessionInfo.host` is the *active*
    /// provider's host, which is the endpoint's URL while an account is in use
    /// — the model library and the commit-message drafter need the real
    /// Ollama, so remember the last one it reported.
    var ollamaHost: String {
        if activeAccount != nil { return lastOllamaHost }
        return sessionInfo?.host ?? lastOllamaHost
    }

    private var lastOllamaHost = "http://127.0.0.1:11434" {
        didSet {
            guard lastOllamaHost != oldValue else { return }
            // The bypass list keeps Ollama direct, so the proxy layer has to
            // hear about the real host the agent just reported.
            ProxyRuntime.shared.noteOllamaHost(lastOllamaHost)
        }
    }
    private var accountCatalogFetchedAt: [UUID: Date] = [:]

    /// Whether the session is running this model through this source. Both
    /// halves matter: two accounts can offer a model of the same name.
    func isCurrentRoute(account: ProviderAccount?, model: String) -> Bool {
        account?.id.uuidString == settings.activeAccountID && model == selectedModel
    }

    /// The closed picker's label. With an account it leads with the account's
    /// short name, because the model name alone no longer says where it runs.
    var modelPickerLabel: String {
        guard let account = activeAccount else {
            return localModels.isEmpty && models.isEmpty ? "Auto" : selectedModel
        }
        return "\(account.shortName) · \(selectedModel)"
    }

    var modelPickerSections: [ModelPickerSection] {
        ModelPickerSection.build(
            localModels: localModels.map(\.name),
            accounts: providerAccounts,
            accountModels: accountModels,
            accountStatus: accountStatus
        )
    }

    var filteredSessions: [SessionSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sessions
            .filter { showArchivedSessions || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.mtime > rhs.mtime
            }
        guard !query.isEmpty else { return filtered }
        return filtered.filter {
            "\($0.displayTitle) \($0.name)".lowercased().contains(query)
        }
    }

    static let otherWorkspaceID = "locus.other-chats"

    var activeWorkspaceID: String {
        SessionSummary.canonicalWorkspacePath(workspacePath)
    }

    /// Folder-backed workspace sections plus a compatibility bucket for old
    /// transcripts whose meta record predates cwd provenance.
    var workspaceChatGroups: [WorkspaceChatGroup] {
        let queryActive = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let chats = filteredSessions
        var chatsByPath = Dictionary(grouping: chats.compactMap { session -> (String, SessionSummary)? in
            guard let path = session.workspacePath else { return nil }
            return (path, session)
        }, by: \.0).mapValues { $0.map(\.1) }

        var profilesByPath: [String: WorkspaceProfile] = [:]
        for profile in workspaceProfiles {
            let path = SessionSummary.canonicalWorkspacePath(profile.path)
            if let existing = profilesByPath[path], existing.lastOpened >= profile.lastOpened {
                continue
            }
            profilesByPath[path] = profile
        }

        var paths = Set(profilesByPath.keys)
        paths.formUnion(chatsByPath.keys)
        paths.insert(activeWorkspaceID)

        var groups = paths.compactMap { path -> WorkspaceChatGroup? in
            let groupChats = (chatsByPath.removeValue(forKey: path) ?? []).sorted(by: Self.sessionSort)
            if queryActive && groupChats.isEmpty { return nil }
            let profile = profilesByPath[path]
            let chatDate = groupChats.map(\.date).max() ?? .distantPast
            let lastOpened = max(profile?.lastOpened ?? .distantPast, chatDate)
            return WorkspaceChatGroup(
                id: path,
                path: path,
                title: URL(fileURLWithPath: path).lastPathComponent,
                chats: groupChats,
                lastOpened: lastOpened,
                isAvailable: FileManager.default.fileExists(atPath: path),
                isOther: false
            )
        }
        groups.sort { lhs, rhs in
            if lhs.id == activeWorkspaceID { return true }
            if rhs.id == activeWorkspaceID { return false }
            return lhs.lastOpened > rhs.lastOpened
        }

        let otherChats = chats.filter { $0.workspacePath == nil }.sorted(by: Self.sessionSort)
        if !otherChats.isEmpty {
            groups.append(
                WorkspaceChatGroup(
                    id: Self.otherWorkspaceID,
                    path: nil,
                    title: "Other Chats",
                    chats: otherChats,
                    lastOpened: otherChats.map(\.date).max() ?? .distantPast,
                    isAvailable: true,
                    isOther: true
                )
            )
        }
        return groups
    }

    private static func sessionSort(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.mtime > rhs.mtime
    }

    func isWorkspaceExpanded(_ id: String) -> Bool {
        expandedWorkspaceIDs.contains(id)
    }

    func setWorkspaceExpanded(_ id: String, expanded: Bool) {
        if expanded {
            expandedWorkspaceIDs.insert(id)
        } else {
            expandedWorkspaceIDs.remove(id)
        }
        persistExpandedWorkspaces()
    }

    var includedContextTokens: Int {
        contextFiles.filter { $0.isIncluded && $0.isAvailable }.reduce(0) {
            $0 + $1.estimatedTokens
        }
    }

    var includedContextCount: Int {
        contextFiles.filter { $0.isIncluded && $0.isAvailable }.count
    }

    var availableChatAttachments: [ChatAttachment] {
        chatAttachments.filter(\.isAvailable)
    }

    /// The only place a window may be assumed: the context pack needs *some*
    /// cap even when no real window is known.
    static let assumedContextWindowTokens = 32_768

    var contextBudgetTokens: Int {
        Int(Double(contextWindowTokens ?? Self.assumedContextWindowTokens) * 0.60)
    }

    var hasPendingPermission: Bool {
        blocks.contains { $0.tool?.status == .awaitingPermission }
    }

    /// Bridged into settings so the choice persists; views observe it through
    /// the published `settings`.
    var thinkingVisibility: ThinkingVisibility {
        get { settings.resolvedThinkingVisibility }
        set { settings.thinkingVisibilityRaw = newValue.rawValue }
    }

    var justChatEnabled: Bool { selectedMode == .ask }

    func setJustChatEnabled(_ enabled: Bool) {
        if enabled {
            selectedMode = .ask
        } else if selectedMode == .ask {
            selectedMode = lastAgenticMode
        }
    }

    /// The permission request the composer prompt shows now — the oldest
    /// awaiting card that actually carries a request id. Derived from
    /// `blocks` so every path that resets or sweeps them (clear, disconnect,
    /// checkpoint restore) dismisses the prompt without extra bookkeeping.
    var activePermissionRequest: ToolPayload? {
        blocks.first(where: {
            $0.tool?.status == .awaitingPermission && $0.tool?.requestID != nil
        })?.tool
    }

    /// The window the meter measures against. The backend's `context_limit`
    /// wins — it is the number compaction budgets against — then the model
    /// list's advertised window. nil means genuinely unknown (remote
    /// endpoints report none); the chip says so instead of inventing one.
    var contextWindowTokens: Int? {
        if let limit = sessionInfo?.contextLimit, limit > 0 { return limit }
        if let window = models.first(where: { $0.name == selectedModel })?.contextLength,
           window > 0 { return window }
        return nil
    }

    /// Session tokens the backend has already counted, plus a rough estimate
    /// for the reply currently streaming (the backend only re-counts at turn
    /// boundaries). The context pack is NOT added here: included files are
    /// embedded into user messages, so `approx_tokens` already contains them
    /// after each send.
    var contextUsedTokens: Int {
        (sessionInfo?.approxTokens ?? 0) + streamedCharsThisTurn / 4
    }

    var activeWorkStartedAt: Date? { turnStartedAt }
    var activeStreamingAssistantID: UUID? { streamingAssistantID }

    var estimatedStreamingTokens: Int { streamedCharsThisTurn / 4 }

    var currentWorkPhase: String {
        if let steeringState { return steeringState }
        if let request = activePermissionRequest {
            return "Waiting for permission · \(request.tool)"
        }
        if let tool = blocks.reversed().compactMap(\.tool).first(where: {
            $0.status == .running || $0.status == .awaitingPermission
        }) {
            return tool.status == .running
                ? "Using \(tool.tool)"
                : "Waiting for permission · \(tool.tool)"
        }
        if let assistant = blocks.last(where: { $0.kind == .assistant && $0.isStreaming }),
           assistant.text.isEmpty,
           !(assistant.reasoningText?.isEmpty ?? true)
        {
            return "Reasoning"
        }
        return isBusy ? "Generating response" : "Ready"
    }

    /// What a conversation may actually occupy — the raw window less the tool
    /// schemas and the room kept for a reply, scaled the way the agent scales
    /// its own estimate. The agent reports it so the meter divides by the same
    /// number compaction compares against; dividing by the raw window is why
    /// compaction used to fire at a displayed ~55%.
    var contextUsableTokens: Int? {
        if let usable = sessionInfo?.usableTokens, usable > 0 { return usable }
        return contextWindowTokens
    }

    var contextWindowUsageFraction: Double? {
        guard let usable = contextUsableTokens, usable > 0 else { return nil }
        return min(max(Double(contextUsedTokens) / Double(usable), 0), 1)
    }

    /// Where the window the meter divides by came from. These are not equally
    /// trustworthy, and the difference matters to anyone reading a fullness
    /// meter: a measured window is what the runtime confirmed, while a published
    /// one is a vendor's documented figure that nothing has verified.
    enum ContextWindowProvenance: String {
        case configured
        case pinned
        case measured
        case reported
        case remembered
        case published
        case unknown

        /// False only for a number nothing observed, which the meter marks.
        var isMeasured: Bool { self != .published && self != .unknown }

        var label: String {
            switch self {
            case .configured: "You set this window"
            case .pinned: "Requested by Locus"
            case .measured: "Measured from Ollama"
            case .reported: "Reported by the endpoint"
            case .remembered: "Measured earlier this model"
            case .published: "Published figure — not measured"
            case .unknown: "Unknown"
            }
        }
    }

    var contextWindowProvenance: ContextWindowProvenance {
        guard let raw = sessionInfo?.contextSource,
              let source = ContextWindowProvenance(rawValue: raw)
        else {
            // An older agent sends no provenance. The window it reports is real,
            // so treat it as measured rather than marking every session assumed.
            return contextWindowTokens == nil ? .unknown : .measured
        }
        return source
    }

    var recentWorkspaceProfiles: [WorkspaceProfile] {
        Array(workspaceProfiles.sorted { $0.lastOpened > $1.lastOpened }.prefix(8))
    }

    // MARK: - Transcript search

    /// Blocks matching the transcript search, in transcript order. Matching
    /// is block-level: tool cards are excluded, and there is no intra-text
    /// highlight — navigation scrolls to and outlines the matched block.
    var transcriptSearchMatches: [UUID] {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return blocks.filter { block in
            switch block.kind {
            case .user, .assistant, .note, .error: block.text.lowercased().contains(query)
            case .tool: false
            }
        }.map(\.id)
    }

    /// The match the selection points at, clamped as blocks or query shrink.
    var currentTranscriptMatch: UUID? {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(max(transcriptSearchSelection, 0), matches.count - 1)]
    }

    enum TranscriptMatchStyle {
        case current
        case other
    }

    func transcriptMatchStyle(for id: UUID) -> TranscriptMatchStyle? {
        guard transcriptSearchPresented else { return nil }
        let matches = transcriptSearchMatches
        guard let index = matches.firstIndex(of: id) else { return nil }
        let current = min(max(transcriptSearchSelection, 0), matches.count - 1)
        return index == current ? .current : .other
    }

    func openTranscriptSearch() {
        transcriptSearchPresented = true
    }

    func closeTranscriptSearch() {
        transcriptSearchPresented = false
        transcriptSearchQuery = ""
    }

    /// Moves the selection by `delta`, wrapping in both directions.
    func advanceTranscriptSearch(_ delta: Int) {
        let count = transcriptSearchMatches.count
        guard count > 0 else { return }
        let clamped = min(max(transcriptSearchSelection, 0), count - 1)
        transcriptSearchSelection = ((clamped + delta) % count + count) % count
    }

    func bootstrap() async {
        let recovery = scheduleRuntimeRecovery(
            reason: "Starting the local services…",
            immediate: true
        )
        await recovery?.value
        requestNotificationAuthorization()
        startRuntimeMonitor()
    }

    @discardableResult
    private func scheduleRuntimeRecovery(
        reason: String,
        immediate: Bool = false
    ) -> Task<Void, Never>? {
        guard !isShuttingDown else { return nil }
        if let runtimeRecoveryTask { return runtimeRecoveryTask }

        let attempt = runtimeRecoveryAttempt
        let delay = immediate ? 0 : BackendService.reconnectDelay(for: attempt)
        let task = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                self.agentRuntimePhase = .recovering(
                    "Restarting the local agent in \(Int(delay)) second\(delay == 1 ? "" : "s")…"
                )
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, !self.isShuttingDown else {
                self.runtimeRecoveryTask = nil
                return
            }
            let recovered = await self.performRuntimeRecovery(reason: reason)
            self.runtimeRecoveryTask = nil
            if recovered {
                self.runtimeRecoveryAttempt = 0
            } else if !self.isShuttingDown {
                self.runtimeRecoveryAttempt += 1
                self.scheduleRuntimeRecovery(reason: "Retrying the local agent.")
            }
        }
        runtimeRecoveryTask = task
        return task
    }

    private func performRuntimeRecovery(reason: String) async -> Bool {
        agentRuntimePhase = runtimeRecoveryAttempt == 0
            ? .starting(reason)
            : .recovering(reason)

        if !(await backendIsHealthy()) {
            guard let configuredURL = URL(string: settings.backendURL),
                  OllamaRuntime.isLoopback(configuredURL)
            else {
                agentRuntimePhase = .unavailable(
                    "The configured agent is unavailable. Locus only auto-starts loopback agents."
                )
                return false
            }

            if backendProcess.isRunning {
                await backendProcess.stopAndWait()
            }
            let preferredPort = backend.currentBaseURL.port ?? configuredURL.port ?? 8791
            switch backendProcess.start(
                root: settings.backendRoot,
                port: preferredPort,
                cwd: workspacePath,
                environmentOverlay: ProxyConfigurator.agentEnvironmentOverlay(
                    settings: settings,
                    ollamaHost: lastOllamaHost
                ),
                proxyCredential: ProxyConfigurator.childCredential(
                    settings: settings,
                    password: persistenceEnabled ? CredentialStore.proxyPassword() : nil
                )
            ) {
            case .running(let endpoint):
                if endpoint != backend.currentBaseURL {
                    backend.updateBaseURL(endpoint)
                }
                backendLogHint = endpoint.port == configuredURL.port
                    ? "Started the bundled local agent service."
                    : "Port \(configuredURL.port ?? 8791) was occupied; started the local agent on port \(endpoint.port ?? 0)."
            case .failed(let message):
                backendLogHint = message
                agentRuntimePhase = .unavailable(message)
                return false
            }

            // A cold bundled Python runtime can take several seconds. An
            // immediate child exit is noticed by the process callback and the
            // failed health check below keeps the same recovery loop moving.
            for _ in 0..<60 {
                guard !Task.isCancelled else { return false }
                if await backendIsHealthy() { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard await backendIsHealthy() else {
            let output = backendProcess.recentOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = output.isEmpty
                ? "The local agent did not become ready."
                : String(output.suffix(1_000))
            backendLogHint = message
            agentRuntimePhase = .unavailable(message)
            return false
        }

        agentRuntimePhase = .online
        // The app is the source of truth for provider routing and credentials,
        // so it must reapply them after every agent restart.
        await applyProvider(announce: false)
        backend.connect()
        return true
    }

    private func startRuntimeMonitor() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
                if await self.backendIsHealthy() {
                    self.agentRuntimePhase = .online
                    self.runtimeRecoveryAttempt = 0
                    var ollamaFailure: RuntimePhase?
                    if self.activeAccount == nil {
                        await self.ensureLocalOllama(at: self.lastOllamaHost)
                        if !self.modelRuntimePhase.isOnline {
                            ollamaFailure = self.modelRuntimePhase
                        }
                    }
                    await self.refreshMetadata()
                    if let ollamaFailure, !self.modelRuntimePhase.isOnline {
                        self.modelRuntimePhase = ollamaFailure
                    }
                    self.backend.connect()
                } else {
                    if self.agentRuntimePhase.isOnline {
                        self.recoverFromLostConnection()
                    }
                    self.agentRuntimePhase = .recovering("Restarting the local agent…")
                    self.scheduleRuntimeRecovery(reason: "The local agent health check failed.")
                }
            }
        }
    }

    private func ensureLocalOllama(at hostValue: String) async {
        guard activeAccount == nil else { return }
        var normalized = hostValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("://") { normalized = "http://\(normalized)" }
        guard let host = URL(string: normalized), OllamaRuntime.isLoopback(host) else {
            modelRuntimePhase = .unavailable(
                "The configured Ollama host is not local, so Locus will not launch it automatically."
            )
            return
        }
        lastOllamaHost = host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if await OllamaRuntime.isHealthy(at: host) {
            modelRuntimePhase = .online
            return
        }

        modelRuntimePhase = modelRuntimePhase.isOnline
            ? .recovering("Restarting Ollama…")
            : .starting("Starting Ollama…")
        switch await ollamaRuntime.ensureRunning(at: host) {
        case .online(let message):
            backendLogHint = message
            modelRuntimePhase = .online
        case .unavailable(let message):
            modelRuntimePhase = .unavailable(message)
        }
    }

    func retryLocalServices() {
        guard !isShuttingDown else { return }
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = nil
        runtimeRecoveryAttempt = 0
        scheduleRuntimeRecovery(reason: "Retrying local services…", immediate: true)
    }

    func shutdown() {
        isShuttingDown = true
        persistCurrentWorkspaceProfile()
        // Flush rather than cancel: a debounced settings write that is still
        // pending at quit would otherwise be dropped.
        persistSettings()
        refreshTask?.cancel()
        runtimeRecoveryTask?.cancel()
        streamFlushDriver.invalidate()
        profilePersistenceTask?.cancel()
        settingsPersistenceTask?.cancel()
        sessionResetWatchdog?.cancel()
        indexTask?.cancel()
        agentInstructionsTask?.cancel()
        backend.disconnect()
        backendProcess.stop()
        ollamaRuntime.stopOwnedCLI()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Workspace file index (@ mentions)

    func refreshWorkspaceIndex(force: Bool = false) {
        // UI tests run against a seeded index; a real scan of the runner's
        // machine would replace it with whatever happens to be on disk.
        guard !isUITesting else { return }
        let root = workspacePath
        // Before the agent reports a session, `workspacePath` falls back to the
        // home directory. Walking all of it is slow, throws thousands of
        // unrelated files at the browser, and is thrown away moments later when
        // the real workspace arrives.
        guard sessionInfo != nil else { return }
        guard force || indexedWorkspacePath != root || workspaceFileIndex.isEmpty else { return }
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                WorkspaceIndex.scan(root: root)
            }.value
            // Deliberately not gated on `Task.isCancelled`. A superseded scan
            // of the same root returns the same answer, and throwing its result
            // away is how the browser ended up reporting "0 of 0 files" with
            // nothing scheduled to try again — the Files tab appearing and a
            // session_info arriving are enough to cancel each other. Only a
            // workspace change makes the result stale, so that is what we test.
            guard let self, self.workspacePath == root else { return }
            self.indexedWorkspacePath = root
            self.workspaceFileIndex = files
        }
    }

    /// Completes the active "@query" token with the chosen file and attaches
    /// it to the context pack.
    func applyMention(_ url: URL) {
        guard let mention = WorkspaceIndex.activeMention(in: draftText) else { return }
        let relative = WorkspaceIndex.relativePath(url, root: workspacePath)
        draftText.replaceSubrange(mention.range, with: "@\(relative) ")
        let standardized = url.standardizedFileURL
        if !contextFiles.contains(where: { $0.url.standardizedFileURL == standardized }) {
            loadContext(from: [url])
        }
    }

    // MARK: - Workspace AGENTS.md

    var agentInstructionsHasUnsavedChanges: Bool {
        agentInstructionsDraft != savedAgentInstructions
    }

    var agentInstructionsURL: URL {
        AgentInstructionsFile.url(for: workspacePath)
    }

    /// Reads the workspace-root AGENTS.md without ever wandering outside the
    /// selected folder. A dirty editor is protected unless the user explicitly
    /// chooses Revert.
    func refreshAgentInstructions(discardingChanges: Bool = false) {
        guard !isUITesting else { return }
        if agentInstructionsHasUnsavedChanges, !discardingChanges {
            showToast("Save or revert the AGENTS.md edits first")
            return
        }

        let root = workspacePath
        agentInstructionsTask?.cancel()
        isLoadingAgentInstructions = true
        agentInstructionsError = nil
        agentInstructionsTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                AgentInstructionsFile.load(from: root)
            }.value
            guard let self, self.workspacePath == root, !Task.isCancelled else { return }
            self.isLoadingAgentInstructions = false
            self.agentInstructionsExists = snapshot.exists
            self.agentInstructionsError = snapshot.error
            guard snapshot.error == nil else { return }
            self.savedAgentInstructions = snapshot.content
            self.agentInstructionsDraft = snapshot.content
        }
    }

    func createAgentInstructions() {
        guard !agentInstructionsExists else {
            refreshAgentInstructions()
            return
        }
        agentInstructionsDraft = "# Workspace instructions\n\n"
        saveAgentInstructions()
    }

    func saveAgentInstructions() {
        guard !isBusy, !hasPendingPermission else {
            showToast("Wait for the current run to finish before saving AGENTS.md")
            return
        }
        guard agentInstructionsHasUnsavedChanges || !agentInstructionsExists else { return }

        let root = workspacePath
        let contents = agentInstructionsDraft
        isSavingAgentInstructions = true
        agentInstructionsError = nil
        agentInstructionsTask?.cancel()
        agentInstructionsTask = Task { [weak self] in
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try AgentInstructionsFile.save(contents, in: root)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self, self.workspacePath == root, !Task.isCancelled else { return }
            self.isSavingAgentInstructions = false
            if let errorMessage {
                self.agentInstructionsError = errorMessage
                self.showToast("Could not save AGENTS.md")
                return
            }

            self.agentInstructionsExists = true
            self.savedAgentInstructions = contents
            self.refreshWorkspaceIndex(force: true)

            do {
                let _: ProjectContextReloadResponse = try await self.backend.post(
                    "/api/context/reload",
                    body: [:],
                    as: ProjectContextReloadResponse.self
                )
                self.showToast("Saved AGENTS.md — instructions reloaded")
            } catch {
                // The file is already safely on disk. The backend also reloads
                // project instructions at the next Work turn, so a reconnect or
                // narrow race with a finishing turn never loses the edit.
                self.showToast("Saved AGENTS.md — applies on the next Work turn")
            }
        }
    }

    func revertAgentInstructions() {
        if agentInstructionsExists {
            refreshAgentInstructions(discardingChanges: true)
        } else {
            agentInstructionsDraft = ""
            savedAgentInstructions = ""
            agentInstructionsError = nil
        }
    }

    func revealAgentInstructionsInFinder() {
        guard agentInstructionsExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([agentInstructionsURL])
    }

    // MARK: - Git branch

    private func refreshGitBranch() {
        let root = workspacePath
        Task { [weak self] in
            let branch = await Task.detached(priority: .utility) {
                Self.gitBranch(at: root)
            }.value
            guard let self, self.workspacePath == root else { return }
            self.gitBranch = branch
        }
    }

    nonisolated static func gitBranch(at root: String) -> String? {
        var gitURL = URL(fileURLWithPath: root).appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            // Worktree/submodule: `.git` is a file containing "gitdir: <path>".
            guard let pointer = try? String(contentsOf: gitURL, encoding: .utf8),
                  let path = pointer
                      .split(separator: "\n")
                      .first(where: { $0.hasPrefix("gitdir:") })?
                      .dropFirst("gitdir:".count)
                      .trimmingCharacters(in: .whitespaces)
            else { return nil }
            gitURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: root).appending(path: path).standardizedFileURL
        }
        guard let head = try? String(
            contentsOf: gitURL.appending(path: "HEAD"),
            encoding: .utf8
        ) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        guard persistenceEnabled, settings.notifyOnCompletion else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTurnCompleteIfInactive() {
        deliverNotification(
            body: "Finished responding in \(URL(fileURLWithPath: workspacePath).lastPathComponent)."
        )
    }

    private func notifyPermissionRequestIfInactive() {
        deliverNotification(body: "Locus needs permission to continue.")
    }

    private func deliverNotification(body: String) {
        guard persistenceEnabled, settings.notifyOnCompletion, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Locus"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    func refreshMetadata() async {
        // UI tests run against seeded fixtures; a live agent on the same port
        // must never replace them mid-test.
        guard !isUITesting else { return }
        do {
            let health = try await backend.get("/api/health", as: HealthResponse.self)
            if activeAccount == nil, let host = health.host, !host.isEmpty {
                lastOllamaHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            modelRuntimePhase = health.ollama
                ? .online
                : .unavailable(health.error ?? "The model provider is unavailable.")
        } catch {
            modelRuntimePhase = agentRuntimePhase.isOnline
                ? .unavailable(error.localizedDescription)
                : .recovering("Waiting for the local agent…")
        }

        do {
            let response = try await backend.get("/api/models", as: ModelsResponse.self)
            models = response.models
            // `/api/models` describes the active provider. Only trust it as the
            // local list when local is what is active.
            if activeAccount == nil { localModels = response.models }
        } catch {
            // Connection state communicates backend failures.
        }
        if activeAccount != nil { await refreshLocalModels() }
        await refreshAccountCatalogs()

        do {
            let suffix = showArchivedSessions
                ? "?include_archived=true&limit=500"
                : "?limit=500"
            let response = try await backend.get("/api/sessions\(suffix)", as: SessionsResponse.self)
            sessions = response.sessions
            currentSessionID = response.current
            if let path = workspaceToOpenAfterReconnect {
                workspaceToOpenAfterReconnect = nil
                let canonical = SessionSummary.canonicalWorkspacePath(path)
                expandedWorkspaceIDs.insert(canonical)
                persistExpandedWorkspaces()
                if let latest = sessions
                    .filter({ $0.workspacePath == canonical })
                    .max(by: { $0.mtime < $1.mtime })
                {
                    resume(latest)
                }
            }
        } catch {
            // Preserve the last-known list during reconnects.
        }

        await refreshExtensions()
        refreshGitBranch()
    }

    // MARK: - Plugins, skills, and MCP

    func refreshExtensions() async {
        guard !isUITesting else { return }
        isLoadingExtensions = true
        defer { isLoadingExtensions = false }
        do {
            let response = try await backend.get("/api/extensions", as: ExtensionsResponse.self)
            extensions = response
            extensionErrorMessage = response.errors.first
            // Reclaim OAuth tokens whose server is gone — but only from a
            // clean read. An empty `errors` is the agent's promise that this
            // list is complete (ExtensionManager._load_state reports a
            // degraded read through it); without that promise a truncated or
            // unreadable state file would present as "no servers" and this
            // would delete live third-party refresh tokens rather than orphans.
            if response.errors.isEmpty {
                CredentialStore.removeOrphanedMCPCredentials(
                    keeping: Set(response.mcpServers.map(\.id))
                )
            }
            await restoreExtensionCredentials(for: response.mcpServers)
            if let response = try? await backend.get("/api/tools", as: ExtensionToolsResponse.self) {
                extensionTools = response.tools
            }
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func refreshExtensionCatalog(query: String = "", marketplaceID: String = "") async {
        do {
            let response = try await backend.get(
                "/api/extensions/catalog",
                query: [
                    URLQueryItem(name: "query", value: query),
                    URLQueryItem(name: "marketplace_id", value: marketplaceID),
                ],
                as: ExtensionCatalogResponse.self
            )
            extensionCatalog = response.entries
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func addMarketplace(source: String, name: String = "") async {
        do {
            _ = try await backend.post(
                "/api/extensions/marketplaces",
                body: ["source": source, "name": name],
                timeout: 190,
                as: ExtensionMarketplace.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func refreshMarketplace(_ id: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/marketplaces/\(id)/refresh",
                body: [:],
                timeout: 190,
                as: ExtensionMarketplace.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeMarketplace(_ id: String) async {
        do {
            _ = try await backend.delete(
                "/api/extensions/marketplaces/\(id)",
                as: ExtensionOperationResponse.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func inspectPlugin(_ entry: ExtensionCatalogEntry) async -> PluginTrustResponse? {
        do {
            return try await backend.get(
                "/api/extensions/catalog/trust",
                query: [
                    URLQueryItem(name: "marketplace_id", value: entry.marketplaceID),
                    URLQueryItem(name: "plugin", value: entry.name),
                ],
                as: PluginTrustResponse.self
            )
        } catch {
            extensionErrorMessage = error.localizedDescription
            return nil
        }
    }

    func inspectUpdate(
        for plugin: ExtensionPlugin
    ) async -> (ExtensionCatalogEntry, PluginTrustResponse)? {
        await refreshExtensionCatalog()
        guard let entry = extensionCatalog.first(where: { $0.id == plugin.id }) else {
            extensionErrorMessage = "The plugin is no longer available from its marketplace."
            return nil
        }
        guard let trust = await inspectPlugin(entry) else { return nil }
        return (entry, trust)
    }

    func installPlugin(
        _ entry: ExtensionCatalogEntry,
        trust: PluginTrustResponse,
        scope: String = "global"
    ) async {
        do {
            let path = entry.installed
                ? "/api/extensions/plugins/update"
                : "/api/extensions/plugins/install"
            let body: [String: Any] = entry.installed
                ? ["id": entry.id, "expected_digest": trust.digest]
                : [
                    "marketplace_id": entry.marketplaceID,
                    "plugin": entry.name,
                    "expected_digest": trust.digest,
                    "scope": scope,
                    "workspace": workspacePath,
                ]
            _ = try await backend.post(
                path,
                body: body,
                timeout: 190,
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
            await refreshExtensionCatalog()
            showToast(entry.installed ? "Plugin updated" : "Plugin installed")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setPlugin(_ id: String, enabled: Bool, scope: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/plugins/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePath,
                ],
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func rollbackPlugin(_ id: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/plugins/rollback",
                body: ["id": id],
                as: ExtensionPlugin.self
            )
            await refreshExtensions()
            showToast("Plugin rolled back")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func uninstallPlugin(_ id: String) async {
        let credentialAccounts = extensions.mcpServers
            .filter { $0.pluginID == id }
            .map { CredentialStore.mcpCredentialKey($0.id) }
        do {
            _ = try await backend.delete(
                "/api/extensions/plugins/\(id)",
                as: ExtensionOperationResponse.self
            )
            for account in credentialAccounts { CredentialStore.remove(account: account) }
            await refreshExtensions()
            await refreshExtensionCatalog()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func importSkill(from source: String, scope: String = "global") async {
        do {
            _ = try await backend.post(
                "/api/extensions/skills/import",
                body: ["source": source, "scope": scope, "workspace": workspacePath],
                as: ExtensionSkill.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setSkill(_ id: String, enabled: Bool, scope: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/skills/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePath,
                ],
                as: ExtensionSkill.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeSkill(_ id: String) async {
        do {
            _ = try await backend.delete(
                "/api/extensions/skills/\(id)",
                as: ExtensionOperationResponse.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func saveMCPServer(_ body: [String: Any]) async {
        do {
            _ = try await backend.post(
                "/api/extensions/mcp",
                body: body,
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setMCPServer(_ id: String, enabled: Bool, scope: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/enable",
                body: [
                    "id": id, "enabled": enabled, "scope": scope,
                    "workspace": workspacePath,
                ],
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func testMCPServer(_ id: String) async {
        do {
            let response = try await backend.post(
                "/api/extensions/mcp/test",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            showToast(response.status?.state == "connected" ? "MCP server connected" : "MCP test finished")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func reconnectMCPServer(_ id: String) async {
        do {
            let response = try await backend.post(
                "/api/extensions/mcp/reconnect",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            showToast(response.status?.state == "connected" ? "MCP server reconnected" : "MCP reconnect finished")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setMCPPolicy(serverID: String, tool: String? = nil, mode: String) async {
        do {
            var body: [String: Any] = ["id": serverID, "mode": mode]
            if let tool { body["tool"] = tool }
            _ = try await backend.post(
                "/api/extensions/mcp/policy",
                body: body,
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func removeMCPServer(_ id: String) async {
        do {
            _ = try await backend.delete(
                "/api/extensions/mcp/\(id)",
                as: ExtensionOperationResponse.self
            )
            CredentialStore.remove(account: CredentialStore.mcpCredentialKey(id))
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func setMCPCredentials(serverID: String, values: [String: Any]) async {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let encoded = String(data: data, encoding: .utf8)
        else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return
        }
        let account = CredentialStore.mcpCredentialKey(serverID)
        let previous = CredentialStore.get(account: account)
        guard CredentialStore.set(encoded, account: account) else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return
        }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": values],
                as: MCPStatusCredentialResponse.self
            )
            await refreshExtensions()
        } catch {
            if let previous {
                CredentialStore.set(previous, account: account)
            } else {
                CredentialStore.remove(account: account)
            }
            extensionErrorMessage = error.localizedDescription
        }
    }

    func clearMCPCredentials(serverID: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": [String: Any]()],
                as: MCPStatusCredentialResponse.self
            )
            CredentialStore.remove(account: CredentialStore.mcpCredentialKey(serverID))
            await refreshExtensions()
            showToast("MCP credentials removed")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func authenticateMCPServer(_ server: ExtensionMCPServer) {
        mcpAuthCoordinator.authorize(server: server) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let values):
                Task { await self.setMCPCredentials(serverID: server.id, values: values) }
            case .failure(let error):
                self.extensionErrorMessage = error.localizedDescription
            }
        }
    }

    private func restoreExtensionCredentials(for servers: [ExtensionMCPServer]) async {
        for server in servers {
            guard let encoded = CredentialStore.get(account: CredentialStore.mcpCredentialKey(server.id)),
                  let data = encoded.data(using: .utf8),
                  let storedValues = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let values = (try? await mcpAuthCoordinator.refreshedCredentialsIfNeeded(storedValues))
                ?? storedValues
            var refreshedToken = false
            if JSONSerialization.isValidJSONObject(values),
               let refreshedData = try? JSONSerialization.data(withJSONObject: values),
               let refreshed = String(data: refreshedData, encoding: .utf8),
               refreshed != encoded {
                CredentialStore.set(refreshed, account: CredentialStore.mcpCredentialKey(server.id))
                refreshedToken = true
            }
            guard server.hasCredentials != true || refreshedToken else { continue }
            _ = try? await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": server.id, "credentials": values],
                as: MCPStatusCredentialResponse.self
            )
        }
    }

    /// Reads the local runtime directly. With an account active the agent has
    /// no Ollama client to ask, but the local models still belong in the picker.
    private func refreshLocalModels() async {
        guard let url = URL(string: lastOllamaHost + "/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await ProxyRuntime.shared.urlSession.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else { return }  // Ollama not running is normal; keep the last list.
        let knownWindows = Dictionary(
            models.map { ($0.name, $0.contextLength) },
            uniquingKeysWith: { first, _ in first }
        )
        localModels = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ModelInfo(
                name: name,
                size: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: (entry["details"] as? [String: Any])?["parameter_size"] as? String ?? "",
                // This route is Ollama's /api/tags, which carries no window at
                // all. Zeroing it unconditionally meant that with an account
                // active, every local model in the picker read as unknown even
                // though the agent had already reported a window for it.
                contextLength: knownWindows[name] ?? 0
            )
        }
    }

    /// Refreshes every account's model list, unless it was fetched recently.
    func refreshAccountCatalogs(force: Bool = false) async {
        guard persistenceEnabled else { return }
        let stale = Date().addingTimeInterval(-Self.accountCatalogTTL)
        let due = providerAccounts.filter { account in
            force || (accountCatalogFetchedAt[account.id] ?? .distantPast) < stale
        }
        guard !due.isEmpty else { return }
        let now = Date()
        for account in due { accountCatalogFetchedAt[account.id] = now }
        await withTaskGroup(of: (UUID, ProviderModelCatalog.Result).self) { group in
            for account in due {
                group.addTask { (account.id, await ProviderModelCatalog.fetch(for: account)) }
            }
            for await (id, result) in group {
                accountModels[id] = result.models
                accountStatus[id] = result.status
            }
        }
    }

    /// Long enough that the 15-second metadata poll cannot hammer a provider,
    /// short enough that a new model shows up without a relaunch.
    private static let accountCatalogTTL: TimeInterval = 300

    func forgetAccountCatalog(_ id: UUID) {
        accountCatalogFetchedAt[id] = nil
        accountModels[id] = nil
        accountStatus[id] = nil
    }

    private func noteLocalHost(from info: SessionInfo) {
        guard info.provider != "remote", !info.host.isEmpty else { return }
        lastOllamaHost = info.host
    }

    func send(_ rawText: String) {
        send(rawText, preservingDraftOnFailure: true)
    }

    private func send(
        _ rawText: String,
        preservingDraftOnFailure: Bool,
        requeueingOnFailure: Bool = false
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasChatAttachments = selectedMode == .ask && !availableChatAttachments.isEmpty
        guard !text.isEmpty || hasChatAttachments else { return }

        // Slash commands that Locus can run itself execute immediately, even
        // mid-run; anything else starting with "/" goes to the agent verbatim.
        if !text.isEmpty, let command = SlashCommand.command(invokedBy: text) {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            recordPrompt(text)
            execute(command, argument: SlashCommand.argument(in: text))
            return
        }

        if isBusy || hasPendingPermission {
            if hasChatAttachments {
                showToast("Wait for the current reply before sending attachments")
                return
            }
            queuedMessages.append(text)
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            showToast(
                hasPendingPermission
                    ? "Queued — answer the permission request to continue"
                    : "Queued — sends when this turn finishes"
            )
            return
        }
        guard isAgentOnline else {
            stashUnsent(text, requeue: requeueingOnFailure, preserveDraft: preservingDraftOnFailure)
            return
        }

        let isSlashPassthrough = SlashCommand.query(from: text) != nil
        // Capture the mode before any asynchronous context work. A user can
        // change the picker while that work is pending; the dispatched turn
        // must keep the safety contract it started with.
        let dispatchedMode = selectedMode
        let dispatchedAttachments = dispatchedMode == .ask ? availableChatAttachments : []
        let messageText = text.isEmpty ? "Please analyze the attached files." : text
        isBusy = true
        turnStartedAt = Date()
        planApprovalPending = false
        planTodosChangedThisTurn = false
        planReadyThisTurn = false
        // Agent-side slash commands (/init and friends) may write todos, but
        // running one is housekeeping, never a plan worth offering to build.
        turnDispatchedInPlanMode = dispatchedMode == .plan && !isSlashPassthrough
        turnDispatchedMode = isSlashPassthrough ? nil : dispatchedMode
        Task { [weak self] in
            guard let self else { return }
            // Just Chat never reaches into the workspace, including through a
            // context pack selected during an earlier agentic turn.
            if dispatchedMode != .ask {
                await refreshContextFiles()
            }
            let payload = isSlashPassthrough
                ? text
                : decoratedPrompt(
                    messageText,
                    mode: dispatchedMode,
                    chatAttachments: dispatchedAttachments
                )
            var request: [String: Any] = [
                "type": "user_message",
                "text": payload,
                "mode": dispatchedMode.rawValue,
            ]
            let imageAttachments: [[String: Any]] = dispatchedAttachments.compactMap { attachment in
                guard attachment.kind == .image,
                      let data = attachment.imageData,
                      let mimeType = attachment.mimeType
                else { return nil }
                return [
                    "name": attachment.name,
                    "mime_type": mimeType,
                    "data": data.base64EncodedString(),
                ]
            }
            if !imageAttachments.isEmpty {
                request["attachments"] = imageAttachments
            }
            guard backend.send(request) else {
                isBusy = false
                turnStartedAt = nil
                turnDispatchedMode = nil
                turnDispatchedInPlanMode = false
                stashUnsent(text, requeue: requeueingOnFailure, preserveDraft: preservingDraftOnFailure)
                return
            }
            if !dispatchedAttachments.isEmpty {
                let sentIDs = Set(dispatchedAttachments.map(\.id))
                chatAttachments.removeAll { sentIDs.contains($0.id) }
                chatAttachmentNotice = nil
            }
            let attachmentLine = dispatchedAttachments.isEmpty
                ? nil
                : "Attached: \(dispatchedAttachments.map(\.name).joined(separator: ", "))"
            let visibleText = [text.nilIfEmpty, attachmentLine]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            blocks.append(ChatBlock(kind: .user, text: visibleText))
            if !text.isEmpty { recordPrompt(text) }
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            if dispatchedMode == .plan {
                selectInspectorTab(.plan)
            }
        }
    }

    /// Where a message goes when it could not be delivered. A drained queue
    /// entry returns to the head of the queue — writing it into the draft
    /// would destroy whatever the user typed while waiting.
    private func stashUnsent(_ text: String, requeue: Bool, preserveDraft: Bool) {
        if requeue {
            queuedMessages.insert(text, at: 0)
            showToast("Kept in queue — reconnect the local agent to send")
        } else if preserveDraft {
            draftText = text
            showToast("Draft kept — reconnect the local agent to send")
        } else {
            showToast("Not sent — reconnect the local agent and try again")
        }
    }

    /// Sends text to the agent verbatim, without local slash-command matching.
    /// `execute(_:argument:)` must use this for commands it forwards (like
    /// /compact) — routing them back through send() would re-match the same
    /// command and recurse without bound.
    private func sendRaw(_ text: String) {
        if isBusy || hasPendingPermission {
            queuedMessages.append(text)
            showToast("Queued — sends when this turn finishes")
            return
        }
        guard isAgentOnline,
              backend.send(["type": "user_message", "text": text])
        else {
            showToast("Reconnect the local agent to run \(text)")
            return
        }
        isBusy = true
        turnStartedAt = Date()
        planApprovalPending = false
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = false
        turnDispatchedMode = nil
        blocks.append(ChatBlock(kind: .user, text: text))
    }

    func submitDraft() {
        if isBusy {
            steerDraft()
        } else {
            send(draftText)
        }
    }

    /// Append the current direction to the active provider turn. The backend
    /// stops only the current generation, preserves completed tool results,
    /// and continues the same turn without an intermediate `turn_done`.
    func steerDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBusy, !hasPendingPermission, !text.isEmpty else { return }
        guard backend.send(["type": "steer", "text": text]) else {
            showToast("Reconnect the local agent — the direction was not sent")
            return
        }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        steeringState = "Applying direction…"
        showToast("Steering the active turn")
    }

    /// Explicitly retain a message for the next independent turn.
    func queueDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queuedMessages.append(text)
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        showToast("Queued for the next turn")
    }

    /// Interrupt now, but do not start the replacement turn until the backend
    /// confirms the old one has fully unwound and persisted its terminal state.
    func stopAndSendDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBusy, !hasPendingPermission, !text.isEmpty else { return }
        guard backend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the active turn could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        pendingStopAndSend = text
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        steeringState = "Stopping before a new turn…"
        showToast("Stopping, then sending as a new turn")
    }

    func removeQueuedMessage(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    private func drainQueuedMessages() {
        guard !isBusy, !hasPendingPermission, !planApprovalPending, !queuedMessages.isEmpty else {
            return
        }
        guard isAgentOnline else { return }
        send(queuedMessages.removeFirst(), preservingDraftOnFailure: false, requeueingOnFailure: true)
    }

    func previousPrompt() {
        guard !promptHistory.isEmpty, !isBusy else { return }
        if promptHistoryCursor == nil {
            // Stash the unsent draft so leaving history restores it.
            stashedDraft = draftText
        }
        let next = min((promptHistoryCursor ?? -1) + 1, promptHistory.count - 1)
        promptHistoryCursor = next
        draftText = promptHistory[next]
    }

    func nextPrompt() {
        guard let cursor = promptHistoryCursor, !isBusy else { return }
        if cursor <= 0 {
            promptHistoryCursor = nil
            draftText = stashedDraft ?? ""
            stashedDraft = nil
        } else {
            promptHistoryCursor = cursor - 1
            draftText = promptHistory[cursor - 1]
        }
    }

    /// True while the composer is showing a recalled history entry, so arrow
    /// keys keep navigating history instead of moving the caret.
    var isBrowsingPromptHistory: Bool {
        promptHistoryCursor != nil
    }

    private func resetHistoryCursorIfEdited() {
        guard let cursor = promptHistoryCursor,
              promptHistory.indices.contains(cursor),
              draftText != promptHistory[cursor]
        else { return }
        promptHistoryCursor = nil
        stashedDraft = nil
    }

    func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Message copied")
    }

    func useAsDraft(_ text: String) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active action before reusing a message")
            return
        }
        draftText = text
        showToast("Message moved to the composer")
    }

    func canRegenerate(_ block: ChatBlock) -> Bool {
        !isBusy
            && !hasPendingPermission
            && block.kind == .assistant
            && !block.isStreaming
            && blocks.last(where: { $0.kind == .assistant })?.id == block.id
    }

    func retryLastResponse() {
        guard !isBusy, !hasPendingPermission,
              blocks.contains(where: { $0.kind == .user })
        else { return }
        guard backend.send(["type": "retry_last"]) else {
            showToast("Reconnect the local agent before retrying")
            return
        }
        pendingRetry = true
        isBusy = true
        turnStartedAt = Date()
        planApprovalPending = false
        planTodosChangedThisTurn = false
        planReadyThisTurn = false
        turnDispatchedInPlanMode = selectedMode == .plan
        turnDispatchedMode = selectedMode
        showToast("Regenerating the last response")
    }

    func stop() {
        // If the interrupt cannot be delivered the run is still live on the
        // agent; leave the busy state to recoverFromLostConnection(), the one
        // place that reconciles cards and spinners after a drop.
        guard backend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the run could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        isBusy = false
        pendingRetry = false
        showToast("Stopping the current run")
    }

    // MARK: - Slash commands

    func execute(_ command: SlashCommand, argument: String) {
        switch command.action {
        case .clearChat, .newSession:
            requestClearChat()
        case .setMode(let mode):
            selectedMode = mode
            showToast(mode == .ask ? "Just Chat is on" : "Switched to \(mode.rawValue.capitalized) mode")
        case .selectModel:
            selectModelMatching(argument)
        case .browseModels:
            modelLibraryPresented = true
        case .refreshModels:
            Task {
                await refreshMetadata()
                showToast("Models refreshed")
            }
        case .createCheckpoint:
            if argument.isEmpty {
                checkpointPresented = true
            } else {
                createCheckpoint(title: argument)
            }
        case .manageCheckpoints:
            checkpointPresented = true
        case .reviewChanges:
            selectInspectorTab(.changes)
        case .openPreview:
            selectInspectorTab(.preview)
        case .addContext:
            addContext()
        case .exportSession:
            exportCurrentSession()
        case .chooseWorkspace:
            chooseWorkspace()
        case .newWorkspace:
            createWorkspace()
        case .openSettings:
            settingsPresented = true
        case .setPermissionMode(let mode):
            setPermissionMode(mode)
        case .showShortcuts:
            shortcutsPresented = true
        case .showHelp:
            let help = SlashCommand.all.map(\.helpLine).joined(separator: "\n")
            blocks.append(ChatBlock(kind: .note, text: "Available commands:\n\(help)"))
        case .copyLastResponse:
            if let last = blocks.last(where: { $0.kind == .assistant && !$0.text.isEmpty }) {
                copyMessage(last.text)
            } else {
                showToast("No response to copy yet")
            }
        case .retryLastResponse:
            retryLastResponse()
        case .stopRun:
            stop()
        case .compact:
            sendRaw("/compact")
        case .setThinkingVisibility:
            setThinkingVisibility(argument)
        }
    }

    private func selectModelMatching(_ argument: String) {
        guard !argument.isEmpty else {
            let installed = models.map(\.name).joined(separator: "\n")
            blocks.append(ChatBlock(
                kind: .note,
                text: installed.isEmpty
                    ? "No Ollama models installed yet — use /models to browse Hugging Face."
                    : "Installed models:\n\(installed)\n\nUse /model <name> to switch."
            ))
            return
        }
        let lower = argument.lowercased()
        let match = models.first { $0.name.caseInsensitiveCompare(argument) == .orderedSame }
            ?? models.first { $0.name.lowercased().contains(lower) }
        if let match {
            selectModel(match.name)
        } else {
            showToast("No installed model matches “\(argument)”")
        }
    }

    private func setThinkingVisibility(_ argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            let options = ThinkingVisibility.allCases
                .map { "/thinking \($0.rawValue) — \($0.detail)" }
                .joined(separator: "\n")
            blocks.append(ChatBlock(
                kind: .note,
                text: "Thinking is \(thinkingVisibility.title.lowercased()).\n\(options)"
            ))
            return
        }
        guard let visibility = ThinkingVisibility(rawValue: trimmed) else {
            showToast("Use /thinking hidden, collapsed, or expanded")
            return
        }
        thinkingVisibility = visibility
        showToast("Thinking \(visibility.title.lowercased())")
    }

    // MARK: - Rewind

    func canRewind(to block: ChatBlock) -> Bool {
        block.kind == .user && !isBusy && !hasPendingPermission
    }

    /// Restores the conversation to the state just before a user message and
    /// places that message back in the composer for editing — Claude Code's
    /// per-message rewind, built on the checkpoint mechanism.
    func rewind(to block: ChatBlock) {
        guard canRewind(to: block),
              let index = blocks.firstIndex(where: { $0.id == block.id })
        else { return }
        let firstLine = block.text
            .components(separatedBy: .newlines)
            .first.map { String($0.prefix(42)) } ?? "message"
        let checkpoint = SessionCheckpoint(
            id: UUID(),
            title: "Rewind point — \(firstLine)",
            createdAt: Date(),
            blocks: Array(blocks.prefix(upTo: index)),
            todos: [],
            contextFiles: contextFiles,
            workspacePath: workspacePath,
            model: selectedModel,
            activePlan: nil
        )
        pendingRewindDraft = block.text
        restore(checkpoint)
    }

    func decide(requestID: String, decision: String) {
        // UI tests drive the prompt against a dead socket; applying the
        // decision locally is what lets the panel advance and dismiss.
        if !isUITesting {
            guard backend.send([
                "type": "permission_decision",
                "request_id": requestID,
                "decision": decision,
            ]) else {
                showToast("The agent disconnected before the decision was sent")
                return
            }
        }
        if let index = blocks.lastIndex(where: { $0.tool?.requestID == requestID }) {
            blocks[index].tool?.status = decision == "deny" ? .denied : .running
        }
    }

    func selectModel(_ model: String) {
        if isBusy {
            pendingProviderSwitch = (activeAccount?.id, model)
            showToast("Switching to \(model) after this turn")
            return
        }
        guard backend.send(["type": "set_model", "model": model]) else {
            showToast("Reconnect before switching models")
            return
        }
        showToast("Switching to \(model)")
    }

    /// Routes the session to a model, switching providers when the model comes
    /// from a different source than the one in use.
    ///
    /// `account` nil means local Ollama. Switching providers replaces the
    /// agent's client, which it refuses to do mid-turn — so a switch requested
    /// during a run is held and applied when the turn finishes.
    func selectModel(account: ProviderAccount?, model: String) {
        let sameSource = account?.id.uuidString == settings.activeAccountID
        guard !sameSource else {
            if let account {
                rememberPreferredModel(model, for: account)
                // The window belongs to the model, not to the account. Sending
                // only `set_model` left the agent budgeting against the model we
                // just switched away from: a Claude account moved from a
                // 1,000,000-token model to a 200,000-token one kept metering
                // against 1,000,000 and would not compact until five times over
                // the real window, failing every request past it.
                Task { [weak self] in
                    await self?.applyProvider(announce: false)
                    // After the provider call, so the transcript records the
                    // switch against the model the agent has actually adopted.
                    self?.selectModel(model)
                }
            } else {
                selectModel(model)
            }
            return
        }
        if let account, !account.hasKey {
            showToast("Add an API key for \(account.displayName) in Settings")
            settingsPresented = true
            return
        }
        guard !isBusy else {
            pendingProviderSwitch = (account?.id, model)
            showToast("Switching to \(account?.displayName ?? "local Ollama") after this turn")
            return
        }
        applyProviderSwitch(accountID: account?.id, model: model)
    }

    /// A provider switch that arrived mid-turn, applied once the agent is idle.
    private var pendingProviderSwitch: (accountID: UUID?, model: String)?

    func applyPendingProviderSwitchIfNeeded() {
        guard let pending = pendingProviderSwitch else { return }
        pendingProviderSwitch = nil
        applyProviderSwitch(accountID: pending.accountID, model: pending.model)
    }

    private func applyProviderSwitch(accountID: UUID?, model: String) {
        if let accountID, let account = providerAccounts.first(where: { $0.id == accountID }) {
            rememberPreferredModel(model, for: account)
            settings.activeAccountID = accountID.uuidString
            settings.provider = .remote
        } else {
            settings.activeAccountID = nil
            settings.provider = .ollama
        }
        persistSettings()
        Task {
            await applyProvider()
            // The remote provider adopts its configured model as it connects;
            // the local runtime keeps whatever it had, so name it explicitly.
            if accountID == nil, !model.isEmpty, model != selectedModel {
                selectModel(model)
            }
            persistCurrentWorkspaceProfile()
        }
    }

    private func rememberPreferredModel(_ model: String, for account: ProviderAccount) {
        guard let index = providerAccounts.firstIndex(where: { $0.id == account.id }),
              providerAccounts[index].preferredModel != model
        else { return }
        providerAccounts[index].preferredModel = model
        persistProviderAccounts()
    }

    func persistProviderAccounts() {
        guard persistenceEnabled else { return }
        ProviderAccountStore.save(providerAccounts)
    }

    /// Adds or updates an account. The key is written here rather than in the
    /// editor so an abandoned sheet leaves nothing behind; `apiKey` nil means
    /// "keep the saved one".
    func saveProviderAccount(_ account: ProviderAccount, apiKey: String?) {
        let effectiveKey = apiKey ?? CredentialStore.get(account: account.keychainAccount) ?? ""
        if let error = RemoteEndpointTester.securityError(
            baseURL: account.resolvedBaseURL,
            apiKey: effectiveKey
        ) {
            showToast(error)
            return
        }
        var updated = account
        updated.name = ProviderAccountStore.uniqueName(
            account.name,
            kind: account.kind,
            existing: providerAccounts,
            excluding: account.id
        )
        if let index = providerAccounts.firstIndex(where: { $0.id == updated.id }) {
            providerAccounts[index] = updated
        } else {
            providerAccounts.append(updated)
        }
        if let apiKey {
            CredentialStore.set(apiKey, account: updated.keychainAccount)
        }
        persistProviderAccounts()
        forgetAccountCatalog(updated.id)
        Task {
            await refreshAccountCatalogs(force: true)
            // The live agent is holding the old endpoint or key until it is
            // told otherwise.
            if updated.id.uuidString == settings.activeAccountID {
                await applyProvider(announce: false)
            }
        }
        showToast("Saved \(updated.displayName)")
    }

    /// Removes an account, its key, and — if it was the one in use — the
    /// routing that depended on it.
    func removeProviderAccount(_ account: ProviderAccount) {
        providerAccounts.removeAll { $0.id == account.id }
        CredentialStore.remove(account: account.keychainAccount)
        persistProviderAccounts()
        forgetAccountCatalog(account.id)
        guard account.id.uuidString == settings.activeAccountID else {
            showToast("Removed \(account.displayName)")
            return
        }
        if isBusy {
            pendingProviderSwitch = (nil, "")
            showToast("Removed \(account.displayName) — local Ollama takes over after this turn")
        } else {
            applyProviderSwitch(accountID: nil, model: "")
            showToast("Removed \(account.displayName) — using local Ollama")
        }
    }

    /// Deletes the stored key. When it belongs to the account in use the
    /// agent is told at once: it holds the key in memory, so leaving it be
    /// would keep spending a credential the user just revoked.
    func removeProviderAccountKey(_ account: ProviderAccount) {
        CredentialStore.remove(account: account.keychainAccount)
        accountStatus[account.id] = .noKey
        forgetAccountCatalog(account.id)
        guard account.id.uuidString == settings.activeAccountID else { return }
        // Sends an empty key, which the agent treats as "clear it". Held until
        // the turn finishes when one is running, because /api/provider refuses
        // mid-turn — and a dropped revocation is the one failure here that
        // costs the user money.
        if isBusy {
            pendingProviderSwitch = (account.id, account.preferredModel)
            showToast("Key removed — the agent drops it when this turn finishes")
        } else {
            Task { await applyProvider(announce: false) }
        }
    }

    /// Records that the endpoint rejected this account's key, so Settings and
    /// the picker can say so instead of leaving the user to guess.
    func noteAccountKeyRejected() {
        guard let account = activeAccount else { return }
        accountStatus[account.id] = .keyRejected
    }

    func activateInstalledModel(_ reference: String) async {
        await refreshMetadata()
        let lowerReference = reference.lowercased()
        // Ollama lists HF pulls as "hf.co/owner/repo:QUANT". Prefer the exact
        // name, then the owner-qualified repository, and only fall back to the
        // bare repo name when it matches a single installed model.
        let repoID = lowerReference
            .replacingOccurrences(of: "hf.co/", with: "")
            .split(separator: ":")
            .first.map(String.init) ?? lowerReference
        let repoName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        var match = models.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
            ?? models.first { $0.name.lowercased().contains(repoID) }
        if match == nil {
            let candidates = models.filter { $0.name.lowercased().contains(repoName) }
            match = candidates.count == 1 ? candidates.first : nil
        }
        guard let match else {
            showToast("Model installed — refresh the model list to select it")
            return
        }
        selectModel(match.name)
        switch HuggingFaceVariant.fit(
            bytes: match.size,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        ) {
        case .fits:
            showToast("Installed and selected \(match.name)")
        case .tight:
            showToast("Installed \(match.name) — it will use most of this Mac's memory")
        case .exceeds:
            showToast("Installed \(match.name) — likely too large for this Mac")
        }
    }

    func requestClearChat() {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish or stop the active run before clearing")
            return
        }
        commandPalettePresented = false
        if blocks.isEmpty {
            clearChatConfirmed()
        } else {
            clearChatConfirmationPresented = true
        }
    }

    func clearChatConfirmed() {
        clearChatConfirmationPresented = false
        // Re-checked here, not just in requestClearChat(): a permission
        // request can arrive while the confirmation alert is open, and
        // clearing then would orphan the backend's blocked decision.
        guard !hasPendingPermission else {
            showToast("Answer the permission request before clearing")
            return
        }
        guard !isBusy, !pendingSessionReset else { return }
        pendingSessionReset = true
        armSessionResetWatchdog()
        showToast("Starting a fresh chat…")
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/new",
                    body: ["reason": "clear_chat"],
                    as: NewSessionResponse.self
                )
                applySessionStarted(response.sessionInfo, reason: response.reason)
            } catch {
                guard pendingSessionReset else { return }
                if (error as NSError).code == 404,
                   backend.send(["type": "new_session"])
                {
                    showToast("Starting a fresh chat…")
                    return
                }
                pendingSessionReset = false
                sessionResetWatchdog?.cancel()
                showToast("Could not clear the chat: \(error.localizedDescription)")
            }
        }
    }

    /// If the backend accepts a reset request but its acknowledgement never
    /// arrives, release the latch so Clear Chat is not silently disabled.
    private func armSessionResetWatchdog() {
        sessionResetWatchdog?.cancel()
        sessionResetWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.pendingSessionReset else { return }
            self.pendingSessionReset = false
            self.pendingCheckpointRestore = nil
            self.pendingRewindDraft = nil
            self.showToast("The agent did not confirm the new session — try again")
        }
    }

    func newSession() {
        requestClearChat()
    }

    func newSession(in workspacePath: String) {
        startNewChat(in: workspacePath)
    }

    func openWorkspace(_ group: WorkspaceChatGroup) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before switching workspaces")
            return
        }
        setWorkspaceExpanded(group.id, expanded: true)
        if let latest = group.chats.max(by: { $0.mtime < $1.mtime }) {
            resume(latest)
        } else if let path = group.path {
            startNewChat(in: path)
        }
    }

    private func startNewChat(in rawPath: String) {
        guard !isBusy, !hasPendingPermission, !pendingSessionReset else {
            showToast("Finish the active run before starting another chat")
            return
        }
        let path = SessionSummary.canonicalWorkspacePath(rawPath)
        guard FileManager.default.fileExists(atPath: path) else {
            showToast("That workspace is no longer available")
            return
        }
        guard workspaceAccess.activateStored(path: path) else {
            showToast("Choose that workspace again to restore access")
            return
        }
        persistCurrentWorkspaceProfile()
        pendingWorkspacePath = path
        initialWorkspacePath = path
        expandedWorkspaceIDs.insert(path)
        persistExpandedWorkspaces()
        pendingSessionReset = true
        armSessionResetWatchdog()
        showToast("Starting a new chat in \(URL(fileURLWithPath: path).lastPathComponent)…")
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/new",
                    body: ["reason": "workspace_chat", "cwd": path],
                    as: NewSessionResponse.self
                )
                applySessionStarted(response.sessionInfo, reason: response.reason)
            } catch {
                pendingSessionReset = false
                pendingWorkspacePath = nil
                sessionResetWatchdog?.cancel()
                showToast("Could not start the chat: \(error.localizedDescription)")
            }
        }
    }

    func requestClearSavedSessions() {
        commandPalettePresented = false
        guard !isClearingSessions else { return }
        clearSessionsConfirmationPresented = true
    }

    func clearSavedSessionsConfirmed() {
        clearSessionsConfirmationPresented = false
        guard !isClearingSessions else { return }
        isClearingSessions = true
        Task {
            do {
                let response = try await backend.delete(
                    "/api/sessions",
                    as: ClearSessionsResponse.self
                )
                let suffix = showArchivedSessions
                    ? "?include_archived=true&limit=500"
                    : "?limit=500"
                let list = try await backend.get(
                    "/api/sessions\(suffix)",
                    as: SessionsResponse.self
                )
                sessions = list.sessions
                currentSessionID = list.current
                if response.count == 0 {
                    showToast("No previous sessions to clear")
                } else {
                    showToast(
                        "\(response.count) saved \(response.count == 1 ? "session" : "sessions") moved to recovery"
                    )
                }
            } catch {
                showToast("Could not clear saved sessions: \(error.localizedDescription)")
            }
            isClearingSessions = false
        }
    }

    func resume(_ session: SessionSummary) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before switching sessions")
            return
        }
        if let path = session.workspacePath {
            guard FileManager.default.fileExists(atPath: path) else {
                showToast("That chat's workspace is no longer available")
                return
            }
            guard workspaceAccess.activateStored(path: path) else {
                showToast("Choose that workspace again to restore access")
                return
            }
            pendingWorkspacePath = path
            initialWorkspacePath = path
            expandedWorkspaceIDs.insert(path)
            persistExpandedWorkspaces()
        }
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/\(session.id)/resume",
                    body: [:],
                    as: ResumeResponse.self
                )
                flushPendingTokens()
                streamingAssistantID = nil
                streamingReply.resetTurn()
                isBusy = false
                todos = []
                activePlan = nil
                planApprovalPending = false
                queuedMessages = []
                restoredTranscriptContext = nil
                // Pre-acknowledge the session's workspace so a later
                // session_info event doesn't wipe the freshly loaded transcript.
                appliedWorkspacePath = response.sessionInfo.cwd
                pendingWorkspacePath = nil
                blocks = Self.blocks(from: response.messages)
                sessionInfo = response.sessionInfo
                currentSessionID = response.sessionInfo.sessionID
                touchWorkspaceProfile(response.sessionInfo.cwd)
                showToast("Session resumed")
            } catch {
                blocks.append(ChatBlock(kind: .error, text: error.localizedDescription))
            }
        }
    }

    func renameSession(_ session: SessionSummary, title: String) {
        updateSession(session, body: ["title": title], success: "Session renamed")
    }

    func togglePin(_ session: SessionSummary) {
        updateSession(session, body: ["pinned": !session.isPinned], success: session.isPinned ? "Session unpinned" : "Session pinned")
    }

    func archive(_ session: SessionSummary) {
        guard session.id != currentSessionID else {
            showToast("Start a new chat before archiving the active session")
            return
        }
        updateSession(session, body: ["archived": !session.isArchived], success: session.isArchived ? "Session restored" : "Session archived")
    }

    func deleteChat(_ session: SessionSummary) {
        guard !isBusy, !hasPendingPermission, !pendingSessionReset else {
            showToast("Finish the active run before deleting a chat")
            return
        }
        let wasActive = session.id == currentSessionID
        if wasActive {
            pendingSessionReset = true
            armSessionResetWatchdog()
        }
        Task {
            do {
                let response = try await backend.delete(
                    "/api/sessions/\(session.id)",
                    as: DeleteSessionResponse.self
                )
                if let replacement = response.replacementSessionInfo {
                    applySessionStarted(replacement, reason: "deleted_active")
                }
                sessions.removeAll { $0.id == session.id }
                pendingDeletedChat = DeletedChatUndo(
                    session: session,
                    trashBatch: response.trashBatch,
                    wasActive: response.deletedActive
                )
                showToast(
                    "Moved “\(session.displayTitle)” to recovery",
                    actionTitle: "Undo",
                    duration: 7
                )
            } catch {
                if wasActive {
                    pendingSessionReset = false
                    sessionResetWatchdog?.cancel()
                }
                showToast("Could not delete the chat: \(error.localizedDescription)")
            }
        }
    }

    func performToastAction() {
        guard toast?.actionTitle != nil, let deletion = pendingDeletedChat else { return }
        toastTask?.cancel()
        toast = nil
        pendingDeletedChat = nil
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/restore",
                    body: ["batch": deletion.trashBatch],
                    as: RestoreSessionsResponse.self
                )
                await refreshMetadata()
                guard response.restored > 0 else {
                    showToast("That chat could not be restored")
                    return
                }
                showToast("Chat restored")
                if deletion.wasActive,
                   let restoredID = response.sessionIDs.first,
                   let restored = sessions.first(where: { $0.id == restoredID })
                {
                    resume(restored)
                }
            } catch {
                showToast("Could not restore the chat: \(error.localizedDescription)")
            }
        }
    }

    func setShowArchived(_ value: Bool) {
        showArchivedSessions = value
        Task { await refreshMetadata() }
    }

    func exportCurrentSession() {
        guard let session = sessions.first(where: { $0.id == currentSessionID }) else {
            showToast("Send a message first — there is no saved session to export yet")
            return
        }
        exportSession(session)
    }

    func exportSession(_ session: SessionSummary) {
        Task {
            do {
                let detail = try await backend.get(
                    "/api/sessions/\(session.id)",
                    as: SessionDetailResponse.self
                )
                let markdown = Self.exportMarkdown(
                    session: session,
                    messages: detail.messages,
                    workspace: detail.cwd,
                    model: detail.model,
                    started: detail.started
                )
                let panel = NSSavePanel()
                panel.title = "Export Locus Session"
                panel.nameFieldStringValue = "\(Self.safeFilename(session.displayTitle)).md"
                if let markdownType = UTType(filenameExtension: "md") {
                    panel.allowedContentTypes = [markdownType]
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                showToast("Session exported")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func chooseWorkspace() {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before adding a workspace")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace"
        panel.message = "Pick a project folder, or use New Folder to start a new one."
        panel.prompt = "Use Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard workspaceAccess.rememberAndActivate(url) else {
            showToast("Locus could not retain access to that workspace")
            return
        }
        switchWorkspace(to: url.path)
    }

    /// Creates a folder and opens it as the workspace in one step.
    func createWorkspace() {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before creating a workspace")
            return
        }
        let panel = NSSavePanel()
        panel.title = "New Workspace"
        panel.message = "Name the folder Locus should create and open as the workspace."
        panel.prompt = "Create Workspace"
        panel.nameFieldLabel = "Workspace name:"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                showToast("A file with that name already exists")
                return
            }
            // The folder already exists — just open it.
            guard workspaceAccess.rememberAndActivate(url) else {
                showToast("Locus could not retain access to that workspace")
                return
            }
            switchWorkspace(to: url.path)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            showToast("Could not create the folder: \(error.localizedDescription)")
            return
        }
        guard workspaceAccess.rememberAndActivate(url) else {
            showToast("Locus could not retain access to that workspace")
            return
        }
        showToast("Created \(url.lastPathComponent)")
        switchWorkspace(to: url.path)
    }

    func switchWorkspace(to path: String) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before switching workspaces")
            return
        }
        let path = SessionSummary.canonicalWorkspacePath(path)
        guard workspaceAccess.activateStored(path: path) else {
            showToast("Choose that workspace again to restore access")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            showToast("That workspace is no longer available")
            removeWorkspaceProfile(path)
            return
        }
        persistCurrentWorkspaceProfile()
        pendingWorkspacePath = path
        initialWorkspacePath = path
        expandedWorkspaceIDs.insert(path)
        persistExpandedWorkspaces()
        if backendProcess.isRunning, WorkspaceAccess.isSandboxed {
            workspaceToOpenAfterReconnect = path
            backend.disconnect()
            sessionInfo = nil
            Task { [backendProcess] in
                await backendProcess.stopAndWait()
                await self.bootstrap()
            }
            showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        if let latest = sessions
            .filter({ $0.workspacePath == path })
            .max(by: { $0.mtime < $1.mtime })
        {
            resume(latest)
        } else {
            startNewChat(in: path)
        }
        showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func removeWorkspaceProfile(_ path: String) {
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        workspaceProfiles.removeAll {
            SessionSummary.canonicalWorkspacePath($0.path) == canonical
        }
        expandedWorkspaceIDs.remove(canonical)
        persistExpandedWorkspaces()
        persistWorkspaceProfiles()
    }

    func addContext() {
        let panel = NSOpenPanel()
        panel.title = "Add files or folders to context"
        panel.prompt = "Add Context"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = workspaceAccess.rememberAndActivate(url)
        }
        loadContext(from: panel.urls)
    }

    func addChatAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach files to this chat message"
        panel.message = "Locus will send only the files you choose. Chat mode cannot browse their folders."
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        loadChatAttachments(from: panel.urls)
    }

    func loadChatAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let remainingSlots = max(10 - chatAttachments.count, 0)
        guard remainingSlots > 0 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            return
        }
        isLoadingChatAttachments = true
        chatAttachmentNotice = "Preparing attachments…"
        let existing = Set(chatAttachments.map { $0.url.standardizedFileURL })
        let selected = Array(urls.prefix(remainingSlots))
        let scopedURLs = selected.filter { $0.startAccessingSecurityScopedResource() }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.readChatAttachments(selected, excluding: existing)
            }.value
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            chatAttachments.append(contentsOf: result.attachments)
            chatAttachmentNotice = result.notice
            isLoadingChatAttachments = false
            showToast(
                result.attachments.isEmpty
                    ? (result.notice ?? "No supported attachments were added")
                    : "Attached \(result.attachments.count) file\(result.attachments.count == 1 ? "" : "s")"
            )
        }
    }

    func removeChatAttachment(_ attachment: ChatAttachment) {
        chatAttachments.removeAll { $0.id == attachment.id }
        if chatAttachments.isEmpty { chatAttachmentNotice = nil }
    }

    func loadContext(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isLoadingContext = true
        contextNotice = "Reading selected files…"
        let existing = Set(contextFiles.map { $0.url.standardizedFileURL })
        let remainingSlots = max(50 - contextFiles.count, 0)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.readContextSelection(urls, excluding: existing, limit: remainingSlots)
            }.value
            guard let self else { return }
            contextFiles.append(contentsOf: result.files)
            contextNotice = result.notice
            isLoadingContext = false
            rebalanceContextBudget()
            scheduleWorkspacePersistence()
            showToast(result.files.isEmpty ? (result.notice ?? "No readable text files were added") : "Added \(result.files.count) context files")
        }
    }

    func refreshContextFiles() async {
        guard !contextFiles.isEmpty else { return }
        let references = contextFiles
        let refreshed = await Task.detached(priority: .utility) {
            references.map(Self.reloadContextReference)
        }.value
        // Merge by id onto the CURRENT list: files removed or added while the
        // refresh ran off-thread must not be resurrected or dropped.
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        contextFiles = contextFiles.map { refreshedByID[$0.id] ?? $0 }
        rebalanceContextBudget()
        scheduleWorkspacePersistence()
    }

    func removeContext(_ file: ContextFile) {
        contextFiles.removeAll { $0.id == file.id }
        scheduleWorkspacePersistence()
    }

    func toggleContext(_ file: ContextFile) {
        guard let index = contextFiles.firstIndex(where: { $0.id == file.id }) else { return }
        guard contextFiles[index].isAvailable else {
            showToast(contextFiles[index].issue ?? "This file is unavailable")
            return
        }
        contextFiles[index].isIncluded.toggle()
        rebalanceContextBudget()
        scheduleWorkspacePersistence()
    }

    func createCheckpoint(title: String? = nil) {
        let fallbackTitle = blocks.last(where: { $0.kind == .user })?.text
            .components(separatedBy: .newlines)
            .first
            .map { String($0.prefix(54)) }
        let checkpoint = SessionCheckpoint(
            id: UUID(),
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? fallbackTitle?.nilIfEmpty
                ?? "Session snapshot",
            createdAt: Date(),
            blocks: blocks,
            todos: todos,
            contextFiles: contextFiles,
            workspacePath: workspacePath,
            model: selectedModel,
            activePlan: activePlan
        )
        checkpoints.insert(checkpoint, at: 0)
        checkpoints = Array(checkpoints.prefix(12))
        persistCheckpoints()
        checkpointPresented = false
        showToast("Session checkpoint created")
    }

    func restore(_ checkpoint: SessionCheckpoint) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before restoring a checkpoint")
            return
        }
        guard workspaceAccess.activateStored(path: checkpoint.workspacePath) else {
            showToast("Choose that workspace again before restoring this checkpoint")
            return
        }
        guard backend.send(["type": "new_session"]) else {
            showToast("Reconnect before restoring a checkpoint")
            return
        }
        pendingSessionReset = true
        pendingCheckpointRestore = checkpoint
        checkpointPresented = false
        showToast("Restoring checkpoint…")
    }

    func delete(_ checkpoint: SessionCheckpoint) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        persistCheckpoints()
    }

    func requestPlan(
        prompt: String = "Create a concise implementation plan for the current request and workspace."
    ) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before creating a plan")
            return
        }
        guard isAgentOnline else {
            showToast("Reconnect the local agent to create a plan")
            return
        }
        selectedMode = .plan
        send(prompt, preservingDraftOnFailure: false)
    }

    /// Resolves the final Plan-mode decision without changing permissions.
    func resolvePlanApproval(_ decision: PlanApprovalDecision) {
        guard planApprovalPending else { return }
        switch decision {
        case .revise:
            planApprovalPending = false
            selectedMode = .plan
            drainQueuedMessages()
        case .cancel:
            planApprovalPending = false
            selectedMode = .work
            drainQueuedMessages()
        case .proceed:
            guard isAgentOnline else {
                showToast("Reconnect the local agent to implement the plan")
                return
            }
            planApprovalPending = false
            selectedMode = .build
            Task { [weak self] in
                guard let self else { return }
                send(
                    "Implement the plan you just created, in order. Keep the todo list updated as you complete each step.",
                    preservingDraftOnFailure: false,
                    requeueingOnFailure: true
                )
            }
        }
    }

    func openPreviewExternally() {
        guard let url = normalizedPreviewURL else {
            showToast("Enter a valid preview URL")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func reloadPreview() {
        previewReloadID = UUID()
        showToast("Preview reloaded")
    }

    func openWorkspaceInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspacePath)])
    }

    func openBackendFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.backendRoot))
    }

    func applySettings(_ newSettings: AppSettings, proxyCredentialChanged: Bool = false) {
        let backendChanged = settings.backendURL != newSettings.backendURL
            || settings.backendRoot != newSettings.backendRoot
        // Accounts are applied as they are edited, so the only routing change
        // that can arrive with the draft is a different active account.
        let providerChanged = settings.provider != newSettings.provider
            || settings.activeAccountID != newSettings.activeAccountID
            // The window rides the provider call, so a change to it alone
            // still has to be pushed or it never reaches the agent.
            || settings.localContextWindow != newSettings.localContextWindow
        let iterationLimitChanged = settings.maxIterations != newSettings.maxIterations
        let proxyChanged = proxyCredentialChanged
            || settings.proxyModeRaw != newSettings.proxyModeRaw
            || settings.proxyTypeRaw != newSettings.proxyTypeRaw
            || settings.proxyHost != newSettings.proxyHost
            || settings.proxyPort != newSettings.proxyPort
            || settings.proxyBypass != newSettings.proxyBypass
            || settings.proxyUsername != newSettings.proxyUsername
        settings = newSettings
        persistSettings()
        settingsPresented = false

        if proxyChanged {
            // Before any restart, so the relaunched agent and every rebuilt
            // session see the new configuration, not the one being replaced.
            ProxyRuntime.shared.update(
                settings: newSettings,
                password: persistenceEnabled ? CredentialStore.proxyPassword() : nil
            )
        }
        // A backend change with an unparseable URL never restarted the agent;
        // keep that, while a proxy change restarts regardless.
        let backendRestartURL = backendChanged ? URL(string: newSettings.backendURL) : nil
        if backendRestartURL != nil || proxyChanged {
            if let backendRestartURL {
                backend.updateBaseURL(backendRestartURL)
            }
            // The agent reads its proxy from the environment at launch, so a
            // proxy change relaunches it the same way a backend change does.
            // The old child must have released the port before bootstrap
            // relaunches, but that wait may not block the main thread — a
            // stubborn child used to beachball Save for up to four seconds.
            Task { [backendProcess] in
                await backendProcess.stopAndWait()
                await self.bootstrap()
            }
            if proxyChanged {
                // The preview webview re-applies its proxy on reload.
                previewReloadID = UUID()
            }
        } else {
            if providerChanged {
                Task { await applyProvider() }
            }
            previewReloadID = UUID()
        }
        if iterationLimitChanged {
            Task { await applyIterationLimit() }
        }
        showToast("Settings saved")
    }

    /// Pushes the tool-step cap to the agent. Not part of the provider payload:
    /// the cap is not provider-scoped, and it takes effect without a restart —
    /// which matters, because the agent otherwise reads it once at startup.
    private func applyIterationLimit() async {
        // 0 is not a legal limit, so "no preference" is expressed by sending the
        // agent's own default rather than by sending zero and being refused.
        let steps = settings.maxIterations ?? AppModel.defaultIterationLimit
        do {
            let state: ConfigStateResponse = try await backend.post(
                "/api/config",
                body: ["max_iterations": steps],
                as: ConfigStateResponse.self
            )
            if let info = state.sessionInfo { sessionInfo = info }
        } catch {
            showToast("Could not set the tool-step limit: \(error.localizedDescription)")
        }
    }

    /// The agent's default, mirrored so clearing the field restores it.
    static let defaultIterationLimit = 40

    /// The `/api/provider` payload for the current routing choice.
    ///
    /// Pure, so the routing rules can be tested without a backend: an account
    /// contributes its endpoint, key, auth style, and label; no account means
    /// the local runtime.
    func providerRequestBody(verify: Bool = false) -> [String: Any] {
        guard let account = activeAccount else {
            var body: [String: Any] = ["provider": "ollama"]
            // Sent every launch, so clearing the field really clears it.
            body["context_window"] = settings.localContextWindow ?? 0
            return body
        }
        return [
            "provider": "remote",
            "base_url": account.resolvedBaseURL,
            "model": account.preferredModel,
            "api_key": CredentialStore.get(account: account.keychainAccount) ?? "",
            "auth_style": account.kind.authStyle,
            "account_label": account.displayName,
            // Kimi Code serves no model listing; without this the agent's
            // health probe reads its auth error on /models as a rejected
            // key and reports a working account as permanently offline.
            "lists_models": account.kind.listsModels,
            // Two separate facts, because they are not equally trustworthy.
            // `context_window` is a number the user typed: it clamps, and the
            // agent reports it as configured. `published_context_window` is our
            // own table's figure for this model: a labelled fallback, used only
            // when the endpoint says nothing about itself, and never recorded as
            // a measurement. Collapsing them — which is what
            // `resolvedContextWindow` does for display — is how a vendor default
            // reached the agent looking like an instruction, and how a stale
            // table entry could silently outrank what the endpoint reported.
            "context_window": account.contextWindow ?? 0,
            "published_context_window":
                account.kind.publishedContextWindow(for: account.preferredModel) ?? 0,
            "verify": verify,
        ]
    }

    /// Pushes the chosen provider to the local agent. The key travels from the
    /// app's credential file to the agent process in memory — the agent never
    /// writes it to its own config, so it is re-sent on every launch.
    func applyProvider(verify: Bool = false, announce: Bool = true) async {
        let account = activeAccount
        if let account, account.resolvedBaseURL.isEmpty {
            if announce {
                showToast("Add the endpoint URL for \(account.displayName) in Settings")
            }
            return
        }
        do {
            let state = try await backend.post(
                "/api/provider",
                body: providerRequestBody(verify: verify),
                as: ProviderStateResponse.self
            )
            var ollamaFailure: RuntimePhase?
            if state.provider == "ollama" {
                lastOllamaHost = state.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                await ensureLocalOllama(at: state.host)
                if !modelRuntimePhase.isOnline {
                    ollamaFailure = modelRuntimePhase
                }
            }
            await refreshMetadata()
            if let ollamaFailure, !modelRuntimePhase.isOnline {
                modelRuntimePhase = ollamaFailure
            }
            guard announce else { return }
            showToast(
                state.provider == "remote"
                    ? "Using \(account?.displayName ?? shortHost(state.host))"
                    : "Using local Ollama"
            )
        } catch {
            if announce {
                showToast("Could not switch model provider: \(error.localizedDescription)")
            }
        }
    }

    private func shortHost(_ value: String) -> String {
        guard let host = URL(string: value)?.host else { return value }
        return host
    }

    // MARK: - Inspector

    /// Seven tab labels need almost the full inspector width; below this the
    /// icon-first strip keeps every target comfortably clickable.
    var inspectorShowsLabels: Bool { inspectorWidth >= 500 }

    /// Files changed in the workspace, for the Changes badge.
    var changedFileCount: Int { gitChanges.count }

    var gitChangeSummary: String {
        guard !gitChanges.isEmpty else { return "No changes" }
        var parts: [String] = []
        let staged = gitChanges.filter(\.staged).count
        let unstaged = gitChanges.filter { $0.unstaged && $0.status != .untracked }.count
        let untracked = gitChanges.filter { $0.status == .untracked }.count
        if staged > 0 { parts.append("\(staged) staged") }
        if unstaged > 0 { parts.append("\(unstaged) modified") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        return parts.joined(separator: " · ")
    }

    /// Reloads the workspace's git status. Safe to call often; overlapping
    /// requests collapse onto the newest.
    func refreshGitStatus() {
        // There is no agent behind a UI test, so a refresh would only empty the
        // seeded change list.
        guard !isUITesting else { return }
        gitStatusTask?.cancel()
        let root = workspacePath
        isRefreshingGitStatus = true
        gitStatusTask = Task { [weak self, backend] in
            // A superseded (cancelled) request must not clear the spinner the
            // newer request just turned on.
            defer { if !Task.isCancelled { self?.isRefreshingGitStatus = false } }
            do {
                let response = try await backend.get(
                    "/api/git/status",
                    query: [URLQueryItem(name: "untracked", value: "all")],
                    as: GitStatusResponse.self
                )
                guard !Task.isCancelled, let self, self.workspacePath == root else { return }
                self.applyGitStatus(response)
            } catch {
                guard !Task.isCancelled, let self, self.workspacePath == root else { return }
                self.applyGitStatusFailure()
            }
        }
    }

    func applyGitStatus(_ response: GitStatusResponse) {
        let previous = Set(gitChanges.map(\.path))
        gitChanges = response.files
        isGitRepository = response.isRepo
        lastGitRefreshFailed = false
        if response.isRepo, let branch = response.branch {
            gitBranch = branch
        }
        if Self.changesAreUnseen(
            previous: previous,
            current: response.files,
            changesTabVisible: inspectorTab == .changes && !inspectorCollapsed
        ) {
            changesHaveUnseenUpdate = true
        }
    }

    /// A transient failure (timeout, agent restarting) keeps the last known
    /// list — emptying it here would render the "Nothing changed" state,
    /// which reads as "your edits are gone". The tab shows a stale hint.
    func applyGitStatusFailure() {
        lastGitRefreshFailed = true
    }

    // MARK: - Git quick actions

    private var gitClient: GitClient {
        GitClient(workspaceRoot: workspacePath)
    }

    var stagedChangeCount: Int {
        gitChanges.filter(\.staged).count
    }

    func stageChange(_ change: GitChange) {
        performGitAction(["add", "--", change.path])
    }

    func unstageChange(_ change: GitChange) {
        // In a repository with no commits yet `restore --staged` cannot
        // resolve HEAD; `rm --cached` is the unstage for that state.
        performGitAction(
            ["restore", "--staged", "--", change.path],
            fallback: ["rm", "--cached", "-q", "--", change.path]
        )
    }

    func requestDiscard(_ change: GitChange) {
        pendingDiscard = change
    }

    func discardConfirmed() {
        guard let change = pendingDiscard else { return }
        pendingDiscard = nil
        if change.status == .untracked {
            // The Trash, not `git clean`: recoverable beats gone.
            let url = URL(fileURLWithPath: workspacePath).appending(path: change.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                showToast("Moved \(change.name) to the Trash")
            } catch {
                showToast(error.localizedDescription)
            }
            refreshGitStatus()
        } else {
            performGitAction(
                ["restore", "--staged", "--worktree", "--", change.path],
                success: "Discarded changes to \(change.name)"
            )
        }
    }

    func commitStaged() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, stagedChangeCount > 0, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                let result = try await client.run(["commit", "-m", message])
                self?.commitMessage = ""
                let summary = result.stdout
                    .split(separator: "\n")
                    .first.map(String.init) ?? "Committed"
                self?.showToast(summary)
            } catch {
                self?.showToast(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshGitStatus()
        }
    }

    /// Fills `commitMessage` with an on-device draft from the staged diff, or
    /// a deterministic summary when no local model can draft. A second press
    /// while drafting cancels the first.
    func draftCommitMessage() {
        if isDraftingCommitMessage {
            commitDraftTask?.cancel()
            isDraftingCommitMessage = false
            return
        }
        let staged = gitChanges.filter(\.staged)
        guard !staged.isEmpty else {
            showToast("Stage a file first — the draft describes staged changes")
            return
        }
        isDraftingCommitMessage = true
        let client = gitClient
        let useLocalModel = settings.provider == .ollama && isModelOnline
        let host = ollamaHost
        let modelName = selectedModel
        commitDraftTask = Task { [weak self] in
            var draft: String?
            if useLocalModel {
                let stat = (try? await client.run(["diff", "--cached", "--stat"]))?.stdout ?? ""
                let diff = (try? await client.run(["diff", "--cached"]))?.stdout ?? ""
                draft = await CommitMessageDrafter.draft(
                    host: host,
                    model: modelName,
                    stat: stat,
                    diff: String(diff.prefix(8_000))
                )
            }
            guard let self, !Task.isCancelled else { return }
            if draft == nil {
                draft = CommitMessageDrafter.template(for: staged)
                showToast(useLocalModel
                    ? "The local model could not draft — used a summary instead"
                    : "Drafted a summary — an AI draft needs local Ollama")
            }
            if let draft, !draft.isEmpty {
                commitMessage = draft
            }
            isDraftingCommitMessage = false
        }
    }

    private func performGitAction(
        _ args: [String],
        fallback: [String]? = nil,
        success: String? = nil
    ) {
        guard isGitRepository, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                do {
                    try await client.run(args)
                } catch {
                    guard let fallback else { throw error }
                    try await client.run(fallback)
                }
                if let success { self?.showToast(success) }
            } catch {
                self?.showToast(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshGitStatus()
        }
    }

    /// Whether a status refresh brought in a change the user has not seen.
    /// Only newly appearing paths count: a file that keeps being edited while
    /// the tab is closed should not re-badge on every refresh.
    nonisolated static func changesAreUnseen(
        previous: Set<String>,
        current: [GitChange],
        changesTabVisible: Bool
    ) -> Bool {
        guard !changesTabVisible else { return false }
        return current.contains { !previous.contains($0.path) }
    }

    /// Loads the diff for one file into `selectedChangeDiff`.
    func loadDiff(for change: GitChange) {
        selectedChangePath = change.path
        selectedChangeDiff = nil
        diffTask?.cancel()
        diffTask = Task { [weak self] in
            do {
                let response = try await self?.backend.get(
                    "/api/git/diff",
                    query: [
                        URLQueryItem(name: "path", value: change.path),
                        URLQueryItem(
                            name: "staged",
                            value: change.staged && !change.unstaged ? "true" : "false"
                        ),
                    ],
                    as: GitDiffResponse.self
                )
                guard !Task.isCancelled, let self, let response else { return }
                guard self.selectedChangePath == change.path else { return }
                self.selectedChangeDiff = Self.cappedDiff(response)
            } catch {
                guard !Task.isCancelled else { return }
                self?.selectedChangeDiff = "Could not load the diff: \(error.localizedDescription)"
            }
        }
    }

    /// Files matching the browser's query. O(n) over a capped index, so this
    /// stays on the main thread rather than adding a task per keystroke.
    var filteredWorkspaceFiles: [URL] {
        WorkspaceIndex.matches(
            query: fileQuery,
            in: workspaceFileIndex,
            root: workspacePath,
            limit: 200
        )
    }

    /// Reads a workspace file for the inline peek.
    func previewFile(_ url: URL) {
        previewedFilePath = WorkspaceIndex.relativePath(url, root: workspacePath)
        previewedFileContents = nil
        filePreviewTask?.cancel()
        filePreviewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      (values.fileSize ?? 0) <= 256_000
                else { return "This file is larger than 256 KB." }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let text = String(data: data, encoding: .utf8)
                else { return "This file is not readable as UTF-8 text." }
                return text
            }.value
            guard !Task.isCancelled, let self else { return }
            guard self.previewedFilePath == WorkspaceIndex.relativePath(url, root: self.workspacePath)
            else { return }
            self.previewedFileContents = result
        }
    }

    func closeFilePreview() {
        filePreviewTask?.cancel()
        previewedFilePath = nil
        previewedFileContents = nil
    }

    /// Inserts an `@path` mention into the composer draft.
    func mentionFileInComposer(_ url: URL) {
        let relative = WorkspaceIndex.relativePath(url, root: workspacePath)
        let separator = draftText.isEmpty || draftText.hasSuffix(" ") ? "" : " "
        draftText += "\(separator)@\(relative) "
        showToast("Mentioned \(url.lastPathComponent)")
    }

    func clearSelectedChange() {
        diffTask?.cancel()
        selectedChangePath = nil
        selectedChangeDiff = nil
    }

    /// Reveals a workspace-relative path in Finder.
    func revealInFinder(_ relativePath: String) {
        let url = URL(fileURLWithPath: workspacePath).appending(path: relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Adds a workspace-relative path to the context pack.
    func addWorkspaceFileToContext(_ relativePath: String) {
        let url = URL(fileURLWithPath: workspacePath).appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("That file is no longer on disk")
            return
        }
        loadContext(from: [url])
    }

    /// DiffTextView builds one Text per line, so a huge diff has to be cut
    /// before it reaches the view even though that stack is lazy.
    static func cappedDiff(_ response: GitDiffResponse, maxLines: Int = 2_000) -> String {
        if response.binary { return "Binary file — no textual diff." }
        guard let raw = response.raw, !raw.isEmpty else {
            return response.ok ? "No changes to show." : "Could not load the diff."
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else {
            return response.truncated ? raw + "\n… diff truncated by the agent." : raw
        }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n… \(lines.count - maxLines) more lines — open the file to see the rest."
    }

    func selectInspectorTab(_ tab: InspectorTab) {
        guard !justChatEnabled else { return }
        inspectorTab = tab
        if inspectorCollapsed {
            inspectorCollapsed = false
        }
        if tab == .plan { planHasUnseenUpdate = false }
        if tab == .changes {
            changesHaveUnseenUpdate = false
            refreshGitStatus()
        }
        if tab == .files { refreshWorkspaceIndex() }
        if tab == .agents { refreshAgentInstructions() }
        settings.inspectorLastTab = tab.rawValue
    }

    func toggleInspector() {
        guard !justChatEnabled else { return }
        inspectorCollapsed.toggle()
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    /// Live width during a drag. Deliberately does not persist — see
    /// `commitInspectorWidth()`.
    func setInspectorWidth(_ width: CGFloat) {
        inspectorWidth = CGFloat(AppSettings.clampInspectorWidth(Double(width)))
    }

    /// Called once when a drag ends. Writing on every frame would restart the
    /// debounced settings save 60 times a second.
    func commitInspectorWidth() {
        settings.inspectorWidth = Double(inspectorWidth)
    }

    // MARK: - Permission mode

    var permissionMode: PermissionMode {
        sessionInfo?.permissions.effectiveMode ?? .ask
    }

    /// Tools the user allowed for the rest of this session.
    var allowedTools: [String] {
        sessionInfo?.permissions.allowed ?? []
    }

    func setPermissionMode(_ mode: PermissionMode) {
        guard mode != permissionMode else { return }
        Task { await changePermissionMode(mode) }
    }

    private func changePermissionMode(_ mode: PermissionMode) async {
        do {
            let state = try await backend.post(
                "/api/permissions",
                body: ["mode": mode.rawValue],
                as: PermissionStateResponse.self
            )
            applyPermissionState(state)
            showToast("Permissions: \(mode.title)")
        } catch {
            showToast("Could not change permissions: \(error.localizedDescription)")
        }
    }

    /// Clears the tools allowed for this session and returns to asking.
    func resetPermissions() {
        Task {
            do {
                let state = try await backend.post(
                    "/api/permissions",
                    body: ["reset": true],
                    as: PermissionStateResponse.self
                )
                applyPermissionState(state)
                showToast("Permissions reset")
            } catch {
                showToast("Could not reset permissions: \(error.localizedDescription)")
            }
        }
    }

    func setComputerControlEnabled(_ enabled: Bool) {
        guard ComputerControlService.isAvailable else {
            settings.computerControlEnabled = false
            showToast("Computer Control is unavailable in the App Store build")
            return
        }
        settings.computerControlEnabled = enabled
        computerControl.refreshPermissionStatus()
        sendComputerControlCapability()
        showToast(enabled ? "Computer Control enabled" : "Computer Control disabled")
    }

    private func sendComputerControlCapability() {
        _ = backend.send([
            "type": "set_computer_control",
            "enabled": settings.computerControlEnabled,
            "native_available": ComputerControlService.isAvailable,
        ])
    }

    /// The agent echoes the new state; mirror it locally so the UI updates
    /// without waiting for the next session_info event.
    private func applyPermissionState(_ state: PermissionStateResponse) {
        guard let info = sessionInfo else { return }
        sessionInfo = info.replacingPermissions(
            SessionPermissions(
                skipAll: state.skipAll,
                allowed: state.allowed,
                mode: PermissionMode(rawValue: state.mode)
            )
        )
    }

    var providerLabel: String {
        let status: String
        switch modelRuntimePhase {
        case .starting: status = "starting"
        case .online: status = "ready"
        case .recovering: status = "recovering"
        case .unavailable: status = "offline"
        }
        guard let account = activeAccount else {
            return "Ollama \(status)"
        }
        let name = account.kind == .custom ? "Endpoint" : account.kind.marketingName
        return "\(name) \(status)"
    }

    func runCommand(_ command: CommandAction) {
        commandPalettePresented = false
        switch command {
        case .newSession: newSession()
        case .clearChat: requestClearChat()
        case .clearSessions: requestClearSavedSessions()
        case .reviewChanges: selectInspectorTab(.changes)
        case .createCheckpoint: checkpointPresented = true
        case .askMode: selectedMode = .ask
        case .workMode: selectedMode = .work
        case .planMode: selectedMode = .plan
        case .buildMode: selectedMode = .build
        case .chooseWorkspace: chooseWorkspace()
        case .newWorkspace: createWorkspace()
        case .browseModels: modelLibraryPresented = true
        case .refreshModels:
            Task {
                await refreshMetadata()
                showToast("Models refreshed")
            }
        case .exportSession: exportCurrentSession()
        case .permissions:
            selectInspectorTab(.plan)
            settingsPresented = true
        case .showShortcuts: shortcutsPresented = true
        case .openSettings: settingsPresented = true
        }
    }

    var normalizedPreviewURL: URL? {
        var value = settings.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://\(value)" }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    func handleEventForTesting(_ event: [String: Any]) {
        handle(event)
    }

    static func migrateLegacyBuildProfiles(_ profiles: [WorkspaceProfile]) -> [WorkspaceProfile] {
        profiles.map { profile in
            guard profile.mode == .build else { return profile }
            var migrated = profile
            migrated.mode = .work
            return migrated
        }
    }

    private func backendIsHealthy() async -> Bool {
        (try? await backend.get("/api/health", as: HealthResponse.self)) != nil
    }

    func decoratedPrompt(
        _ text: String,
        mode: WorkMode,
        chatAttachments: [ChatAttachment] = []
    ) -> String {
        var sections = [
            "[Locus mode: \(mode.rawValue.capitalized)]",
            mode.instruction,
        ]

        let included = contextFiles.filter { $0.isIncluded && $0.isAvailable }
        if mode != .ask, !included.isEmpty {
            let context = included.map {
                """
                --- \($0.displayPath) ---
                \($0.content)
                """
            }.joined(separator: "\n\n")
            sections.append("Use this explicitly selected context:\n\(context)")
        }

        if mode == .ask {
            let suppliedText = chatAttachments.filter {
                $0.kind == .text && $0.isAvailable
            }
            if !suppliedText.isEmpty {
                let contents = suppliedText.compactMap { attachment -> String? in
                    guard let content = attachment.textContent else { return nil }
                    return """
                    --- Attached file: \(attachment.name) ---
                    \(content)
                    """
                }.joined(separator: "\n\n")
                sections.append(
                    "The user explicitly attached the following files to this message. "
                    + "Analyze only the supplied content; do not inspect their paths or access "
                    + "any other workspace data:\n\(contents)"
                )
            }
            let imageNames = chatAttachments.filter {
                $0.kind == .image && $0.isAvailable
            }.map(\.name)
            if !imageNames.isEmpty {
                sections.append(
                    "The user explicitly attached these images to this message: "
                    + imageNames.joined(separator: ", ")
                    + ". Analyze the attached image data without accessing their paths."
                )
            }
        }

        if let restoredTranscriptContext {
            sections.append("Restored session context:\n\(restoredTranscriptContext)")
            self.restoredTranscriptContext = nil
        }

        sections.append("User request:\n\(text)")
        return sections.joined(separator: "\n\n")
    }

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session_info":
            if let info = decode(SessionInfo.self, from: event) {
                computerControl.beginSession(info.sessionID)
                sessionInfo = info
                currentSessionID = info.sessionID
                // Only when a reply is not mid-flight. `approx_tokens` counts
                // the assistant message once it has been committed, which
                // happens at message_end — the same moment streamingAssistantID
                // clears. A session_info arriving before that (changing
                // permission mode does it, and it is busy-guarded on neither
                // side) does not include the text streamed so far, so clearing
                // the estimate would drop it and the meter would visibly fall.
                if streamingAssistantID == nil {
                    streamedCharsThisTurn = 0
                    streamingReply.resetTurn()
                }
                noteLocalHost(from: info)
                applyWorkspaceProfileIfNeeded(for: info)
            }

        case "session_started":
            guard let raw = event["session_info"] as? [String: Any],
                  let info = decode(SessionInfo.self, from: raw)
            else { return }
            applySessionStarted(info, reason: event["reason"] as? String)

        case "message_start":
            startAssistantStream()

        case "token":
            // A token without a preceding message_start (e.g. after a
            // reconnect mid-turn) still deserves a visible bubble.
            if streamingAssistantID == nil {
                startAssistantStream()
            }
            enqueueToken(event["text"] as? String ?? "")

        case "message_end":
            flushPendingTokens()
            if let id = streamingAssistantID { commitStreamingReply(id, finished: true) }
            streamingAssistantID = nil
            streamRevision += 1

        case "tool_call_proposed":
            flushPendingTokens()
            let payload = ToolPayload(
                toolID: event["id"] as? String ?? UUID().uuidString,
                tool: event["tool"] as? String ?? "tool",
                summary: event["summary"] as? String ?? "",
                detail: event["detail"] as? String ?? "",
                status: (event["auto"] as? Bool) == true ? .running : .awaitingPermission
            )
            blocks.append(ChatBlock(kind: .tool, tool: payload))

        case "permission_request":
            let toolID = event["id"] as? String ?? ""
            let preview = event["preview"] as? [String: Any]
            let requestID = (event["request_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let requestID else {
                // A request the app can never answer must not arm the
                // blocking awaiting state — that would disable send and
                // clear-chat with no way out.
                let explanation = "The agent sent a permission request the app cannot answer"
                    + " (missing request id). Stop the run if it does not continue."
                if let index = blocks.lastIndex(where: { $0.tool?.toolID == toolID }), !toolID.isEmpty {
                    blocks[index].tool?.status = .error
                    blocks[index].tool?.result = explanation
                } else {
                    blocks.append(ChatBlock(kind: .error, text: explanation))
                }
                return
            }
            if let index = blocks.lastIndex(where: { $0.tool?.toolID == toolID }), !toolID.isEmpty {
                blocks[index].tool?.status = .awaitingPermission
                blocks[index].tool?.requestID = requestID
                // Publish the in-place tool-card upgrade even though the
                // block count did not change. The native scroll coordinator
                // decides independently whether the viewport should follow.
                streamRevision += 1
            } else {
                // Never drop a permission request: without a card the backend
                // would wait forever for a decision no UI can produce.
                blocks.append(ChatBlock(kind: .tool, tool: ToolPayload(
                    toolID: toolID.isEmpty ? UUID().uuidString : toolID,
                    tool: event["tool"] as? String ?? "tool",
                    summary: event["summary"] as? String
                        ?? preview?["summary"] as? String ?? "Permission requested",
                    detail: event["detail"] as? String
                        ?? preview?["detail"] as? String ?? "",
                    status: .awaitingPermission,
                    requestID: requestID
                )))
            }
            notifyPermissionRequestIfInactive()

        case "tool_result":
            let toolID = event["id"] as? String ?? ""
            let denied = event["denied"] as? Bool == true
            let ok = event["ok"] as? Bool == true
            if let index = blocks.firstIndex(where: { $0.tool?.toolID == toolID }) {
                blocks[index].tool?.status = denied ? .denied : ok ? .done : .error
                blocks[index].tool?.result = event["result"] as? String
            } else {
                // Never drop a result: without a matching card the outcome of
                // a tool the user approved would vanish silently.
                blocks.append(ChatBlock(kind: .tool, tool: ToolPayload(
                    toolID: toolID.isEmpty ? UUID().uuidString : toolID,
                    tool: event["tool"] as? String ?? "tool",
                    summary: event["summary"] as? String ?? "Tool result",
                    detail: "",
                    status: denied ? .denied : ok ? .done : .error,
                    result: event["result"] as? String
                )))
            }

        case "terminal_started", "terminal_output", "terminal_exit",
             "terminal_error", "terminal_state":
            terminal.handle(event)
            if type == "terminal_exit" { refreshGitStatus() }

        case "workspace_changed":
            // The agent touched the tree; the Changes panel is now stale.
            refreshGitStatus()

        case "extensions_changed", "mcp_status", "mcp_credential_refresh":
            extensionRefreshTask?.cancel()
            extensionRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                await self?.refreshExtensions()
            }

        case "mcp_auth_required":
            let name = event["server_name"] as? String ?? "MCP server"
            extensionErrorMessage = "\(name) needs authentication in Settings → Extensions."
            showToast("MCP authentication needed")

        case "note":
            // Backend-side commentary: auto-compaction, truncated output.
            if let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                blocks.append(
                    ChatBlock(kind: (event["error"] as? Bool) == true ? .error : .note, text: text)
                )
            }

        case "thinking":
            // Keep only reasoning text explicitly supplied by the provider;
            // signatures and redacted blocks never enter this event.
            if streamingAssistantID == nil {
                startAssistantStream()
            }
            enqueueReasoning(event["text"] as? String ?? "")

        case "steer_ack":
            let state = event["state"] as? String
            steeringState = state == "after_current_action"
                ? "Waiting for the active action…"
                : "Redirecting generation…"

        case "steer_applied":
            if let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                blocks.append(ChatBlock(kind: .user, text: text))
            }
            steeringState = nil

        case "computer_action_request":
            guard let requestID = event["request_id"] as? String,
                  let tool = event["tool"] as? String,
                  let arguments = event["arguments"] as? [String: Any]
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.computerControl.perform(
                    tool: tool,
                    arguments: arguments,
                    hostedProvider: self.activeAccount?.displayName,
                    timeoutMilliseconds: event["timeout_ms"] as? Int ?? 60_000
                )
                _ = self.backend.send([
                    "type": "computer_action_result",
                    "request_id": requestID,
                    "result": result,
                ])
            }

        case "computer_control_status":
            if (event["enabled"] as? Bool) != true, settings.computerControlEnabled {
                showToast("Computer Control is unavailable from the native broker")
            }

        case "todo_update":
            if let raw = event["todos"] as? [[String: Any]] {
                let updatedTodos = raw.compactMap { decode(TodoItem.self, from: $0) }
                let changed = updatedTodos != todos
                todos = updatedTodos
                if todos.isEmpty {
                    // A prompt offering to implement zero steps is nonsense;
                    // the agent emptying the list withdraws the plan.
                    planApprovalPending = false
                    activePlan = nil
                } else if changed {
                    planTodosChangedThisTurn = true
                }
                // Badge rather than switch: being pulled off the tab you are
                // reading mid-run is the complaint this replaces.
                if !todos.isEmpty, inspectorTab != .plan || inspectorCollapsed {
                    planHasUnseenUpdate = true
                }
            }

        case "plan_ready":
            if let raw = event["plan"] as? [String: Any],
               let plan = decode(PlanDocument.self, from: raw),
               !plan.steps.isEmpty
            {
                activePlan = plan
                planReadyThisTurn = true
                todos = plan.steps.map { TodoItem(content: $0, status: .pending) }
                if inspectorTab != .plan || inspectorCollapsed {
                    planHasUnseenUpdate = true
                }
            }

        case "turn_done":
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            let reason = event["reason"] as? String ?? "complete"
            let dispatchedMode = turnDispatchedMode
                ?? (turnDispatchedInPlanMode ? .plan : nil)
            if reason == "complete", dispatchedMode == .build {
                reconcileFinishedPlanStep()
            }
            appendTurnCompletion(
                reason: reason,
                mode: dispatchedMode,
                backendDurationMilliseconds: event["duration_ms"] as? Int
            )
            isBusy = false
            pendingRetry = false
            steeringState = nil
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            streamingReply.resetTurn()
            if reason == "complete", turnDispatchedInPlanMode, selectedMode == .plan {
                let assistantText = blocks.last(where: { $0.kind == .assistant })?.text ?? ""
                if !planReadyThisTurn,
                   let fallback = PlanSignalDetector.document(
                    from: assistantText,
                    changedTodos: planTodosChangedThisTurn ? todos : []
                   )
                {
                    activePlan = fallback
                    planReadyThisTurn = true
                }
                planApprovalPending = planReadyThisTurn
                    && !(activePlan?.steps.isEmpty ?? true)
                    && !PlanSignalDetector.isClarifyingResponse(assistantText)
            }
            planTodosChangedThisTurn = false
            planReadyThisTurn = false
            turnDispatchedInPlanMode = false
            turnDispatchedMode = nil
            turnStartedAt = nil
            notifyTurnCompleteIfInactive()
            if persistenceEnabled {
                Task { await refreshMetadata() }
            }
            // Before the queue drains: a model chosen mid-turn is meant for
            // the messages waiting behind it.
            applyPendingProviderSwitchIfNeeded()
            if let replacement = pendingStopAndSend {
                pendingStopAndSend = nil
                send(replacement, preservingDraftOnFailure: false, requeueingOnFailure: true)
                return
            }
            Task { @MainActor [weak self] in
                self?.drainQueuedMessages()
            }

        case "error":
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            pendingRetry = false
            steeringState = nil
            planApprovalPending = false
            planTodosChangedThisTurn = false
            turnDispatchedInPlanMode = false
            turnDispatchedMode = nil
            pendingSessionReset = false
            pendingCheckpointRestore = nil
            pendingRewindDraft = nil
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            streamingReply.resetTurn()
            blocks.append(
                ChatBlock(
                    kind: .error,
                    text: annotatingRejectedKey(event["message"] as? String ?? "Unknown agent error")
                )
            )
            // `error` describes the failed operation; the backend still emits
            // `turn_done` after it has finished unwinding. Stay busy until that
            // terminal event so queued messages and state changes cannot race
            // the worker's final session writes.

        case "command_error":
            let message = annotatingRejectedKey(
                event["message"] as? String ?? "The command was rejected."
            )
            blocks.append(ChatBlock(kind: .error, text: message))
            showToast(message)

        case "slash_result":
            isBusy = false
            applyPendingProviderSwitchIfNeeded()
            if event["command"] as? String == "clear" {
                blocks = []
                todos = []
                activePlan = nil
                planApprovalPending = false
            } else if let text = event["text"] as? String, !text.isEmpty {
                blocks.append(
                    ChatBlock(
                        kind: (event["error"] as? Bool) == true ? .error : .note,
                        text: text
                    )
                )
            }

        default:
            break
        }
    }

    /// A rejected key is the one turn failure the user can fix immediately, so
    /// say whose key it was and where to change it.
    private func annotatingRejectedKey(_ message: String) -> String {
        guard message.localizedCaseInsensitiveContains("rejected the API key"),
              let account = activeAccount
        else { return message }
        accountStatus[account.id] = .keyRejected
        return "\(message)\n\nUpdate the key for \(account.displayName) in Settings → Model providers."
    }

    private func applySessionStarted(_ info: SessionInfo, reason: String?) {
        let isDuplicateAcknowledgement = currentSessionID == info.sessionID
            && !pendingSessionReset
            && !pendingRetry
            && pendingCheckpointRestore == nil
        computerControl.beginSession(info.sessionID)
        sessionInfo = info
        currentSessionID = info.sessionID
        if isDuplicateAcknowledgement { return }
        sessionResetWatchdog?.cancel()

        if let checkpoint = pendingCheckpointRestore {
            pendingCheckpointRestore = nil
            pendingSessionReset = false
            backend.send(["type": "set_cwd", "path": checkpoint.workspacePath])
            backend.send(["type": "set_model", "model": checkpoint.model])
            // Pre-acknowledge the checkpoint's workspace: the set_cwd
            // session_info ack must not be treated as a user workspace switch,
            // which would wipe the transcript we are about to restore.
            appliedWorkspacePath = checkpoint.workspacePath
            pendingWorkspacePath = nil
            blocks = checkpoint.blocks
            todos = checkpoint.todos
            activePlan = checkpoint.activePlan
            planApprovalPending = false
            contextFiles = checkpoint.contextFiles
            queuedMessages = []
            restoredTranscriptContext = transcriptContext(from: checkpoint.blocks)
            if let rewindDraft = pendingRewindDraft {
                pendingRewindDraft = nil
                draftText = rewindDraft
                showToast("Rewound — edit the message and send again")
            } else {
                blocks.append(
                    ChatBlock(
                        kind: .note,
                        text: "Restored “\(checkpoint.title)”. The next turn will receive this restored session context."
                    )
                )
                showToast("Checkpoint restored")
            }
            Task { await refreshContextFiles() }
        } else if reason == "retry" || pendingRetry {
            flushPendingTokens()
            if let userIndex = blocks.lastIndex(where: { $0.kind == .user }) {
                blocks = Array(blocks.prefix(through: userIndex))
            }
            todos = []
            activePlan = nil
            planApprovalPending = false
            planTodosChangedThisTurn = false
            pendingRetry = false
            isBusy = true
        } else if pendingSessionReset
                    || reason == "clear_chat"
                    || reason == "workspace_chat"
                    || reason == "deleted_active"
        {
            flushPendingTokens()
            blocks = []
            todos = []
            activePlan = nil
            planApprovalPending = false
            queuedMessages = []
            streamingAssistantID = nil
            streamingReply.resetTurn()
            restoredTranscriptContext = nil
            pendingSessionReset = false
            isBusy = false
            showToast(reason == "deleted_active" ? "Fresh chat opened" : "Fresh chat started")
        }
        if persistenceEnabled {
            Task { await refreshMetadata() }
        }
    }

    private func startAssistantStream() {
        flushPendingTokens()
        if let current = streamingAssistantID {
            commitStreamingReply(current, finished: true)
        }
        let id = UUID()
        streamingAssistantID = id
        isBusy = true
        blocks.append(ChatBlock(id: id, kind: .assistant, isStreaming: true))
        streamingReply.begin(id: id)
    }

    /// No assistant bubble may stay in the streaming state once the turn is
    /// over — a missed message_end otherwise leaves a blinking cursor forever.
    private func finalizeStreamingBlocks() {
        if let id = streamingAssistantID {
            commitStreamingReply(id, finished: true)
        }
        for index in blocks.indices where blocks[index].isStreaming {
            blocks[index].isStreaming = false
        }
    }

    private func commitStreamingReply(_ id: UUID, finished: Bool) {
        guard let snapshot = streamingReply.finish(id: id),
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return }
        blocks[index].text = snapshot.text
        blocks[index].reasoningText = snapshot.reasoning.nilIfEmpty
        if finished { blocks[index].isStreaming = false }
    }

    /// A normally completed Build turn is authoritative evidence that the
    /// step it left active has finished. Pending steps remain pending: this
    /// fixes the common final-step bookkeeping omission without claiming work
    /// the model never started.
    private func reconcileFinishedPlanStep() {
        guard todos.contains(where: { $0.status == .inProgress }) else { return }
        todos = todos.map { todo in
            guard todo.status == .inProgress else { return todo }
            return TodoItem(content: todo.content, status: .completed)
        }
        if inspectorTab != .plan || inspectorCollapsed {
            planHasUnseenUpdate = true
        }
    }

    private func appendTurnCompletion(
        reason: String,
        mode: WorkMode?,
        backendDurationMilliseconds: Int?
    ) {
        let measured = turnStartedAt.map {
            max(Int(Date().timeIntervalSince($0) * 1_000), 0)
        }
        guard let duration = backendDurationMilliseconds ?? measured else { return }
        // A repeated terminal event must not leave a row of duplicate marks.
        guard blocks.last?.completion == nil else { return }
        let outcome = TurnCompletion.Outcome(reason: reason)
        let completion = TurnCompletion(
            outcome: outcome,
            mode: mode,
            durationMilliseconds: duration,
            // Carried only for the outcome it explains, so an ordinary finished
            // turn does not persist a number nothing reads.
            iterationLimit: outcome == .maxIterations ? sessionInfo?.maxIterations : nil
        )
        blocks.append(ChatBlock(kind: .note, completion: completion))
    }

    /// No card may stay awaiting once the turn is over: a decision can no
    /// longer matter, and a stuck awaiting card would disable send and
    /// clear-chat forever.
    private func resolveDanglingPermissions() {
        for index in blocks.indices where blocks[index].tool?.status == .awaitingPermission {
            blocks[index].tool?.status = .error
            blocks[index].tool?.result = "The turn ended before this request was answered."
        }
    }

    /// Called when the WebSocket drops mid-session: resolve every UI state
    /// that only a backend event could clear, so nothing stays stuck.
    private func recoverFromLostConnection() {
        flushPendingTokens()
        finalizeStreamingBlocks()
        streamingAssistantID = nil
        streamedCharsThisTurn = 0
        streamingReply.resetTurn()
        turnStartedAt = nil
        isBusy = false
        pendingRetry = false
        // A pending "implement this plan?" survives the blip on purpose: the
        // decision is client-side state, and answering "implement" while
        // still disconnected is caught by resolvePlanApproval's guard.
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = false
        turnDispatchedMode = nil
        pendingSessionReset = false
        pendingCheckpointRestore = nil
        pendingRewindDraft = nil
        sessionResetWatchdog?.cancel()
        for index in blocks.indices where blocks[index].tool?.status == .awaitingPermission
            || blocks[index].tool?.status == .running
        {
            blocks[index].tool?.status = .error
            blocks[index].tool?.result = "The connection to the local agent was lost before this finished."
        }
        terminal.connectionLost()
    }

    private func enqueueToken(_ token: String) {
        guard !token.isEmpty else { return }
        pendingTokens += token
        scheduleStreamFlush()
    }

    private func enqueueReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        pendingReasoning += text
        scheduleStreamFlush()
    }

    /// A single publication on the next display refresh keeps text growth and
    /// native scroll anchoring on the same visual frame.
    private func scheduleStreamFlush() {
        streamFlushDriver.request()
    }

    private func flushPendingTokens() {
        streamFlushDriver.cancelPending()
        guard !pendingTokens.isEmpty || !pendingReasoning.isEmpty,
              streamingAssistantID != nil
        else {
            pendingTokens = ""
            pendingReasoning = ""
            return
        }
        streamingReply.append(text: pendingTokens, reasoning: pendingReasoning)
        streamedCharsThisTurn += pendingTokens.count + pendingReasoning.count
        pendingTokens = ""
        pendingReasoning = ""
    }

    private func updateSession(_ session: SessionSummary, body: [String: Any], success: String) {
        Task {
            do {
                _ = try await backend.patch(
                    "/api/sessions/\(session.id)",
                    body: body,
                    as: SessionMetadataResponse.self
                )
                await refreshMetadata()
                showToast(success)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func applyWorkspaceProfileIfNeeded(for info: SessionInfo) {
        let path = SessionSummary.canonicalWorkspacePath(info.cwd)
        guard appliedWorkspacePath != path || pendingWorkspacePath == path else { return }
        let changedWorkspace = appliedWorkspacePath != nil && appliedWorkspacePath != path
        appliedWorkspacePath = path
        pendingWorkspacePath = nil
        expandedWorkspaceIDs.insert(path)
        persistExpandedWorkspaces()
        if changedWorkspace {
            flushPendingTokens()
            blocks = []
            todos = []
            activePlan = nil
            planApprovalPending = false
            restoredTranscriptContext = nil
        }
        if let profile = workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            draftText = profile.draft
            selectedMode = profile.mode
            settings.previewURL = profile.previewURL
            contextFiles = profile.contextFiles
            applyProfileRoute(profile, currentModel: info.model)
            Task { await refreshContextFiles() }
        }
        touchWorkspaceProfile(path)
        refreshGitBranch()
        refreshWorkspaceIndex(force: true)
    }

    /// Restores the model a workspace was last used with, through the account
    /// it belonged to.
    private func applyProfileRoute(_ profile: WorkspaceProfile, currentModel: String) {
        guard !profile.model.isEmpty else { return }
        guard profile.accountID != settings.activeAccountID || profile.model != currentModel
        else { return }
        if let accountID = profile.accountID {
            // An account deleted since this workspace was last open leaves the
            // session where it is rather than routing somewhere unintended.
            guard let account = providerAccounts.first(where: { $0.id.uuidString == accountID })
            else { return }
            selectModel(account: account, model: profile.model)
        } else if settings.activeAccountID == nil {
            // Still on the local runtime: only the model has to change, and
            // only if it is actually installed.
            if localModels.contains(where: { $0.name == profile.model }) {
                backend.send(["type": "set_model", "model": profile.model])
            }
        } else {
            selectModel(account: nil, model: profile.model)
        }
    }

    private func touchWorkspaceProfile(_ path: String) {
        let path = SessionSummary.canonicalWorkspacePath(path)
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            workspaceProfiles[index].lastOpened = Date()
        } else {
            workspaceProfiles.append(
                WorkspaceProfile(
                    path: path,
                    lastOpened: Date(),
                    model: selectedModel,
                    accountID: settings.activeAccountID,
                    mode: selectedMode,
                    previewURL: settings.previewURL,
                    contextFiles: contextFiles,
                    draft: draftText
                )
            )
        }
        workspaceProfiles.sort { $0.lastOpened > $1.lastOpened }
        persistWorkspaceProfiles()
    }

    private func scheduleSettingsPersistence() {
        guard persistenceEnabled else { return }
        settingsPersistenceTask?.cancel()
        settingsPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.persistSettings()
        }
    }

    private func scheduleWorkspacePersistence() {
        guard persistenceEnabled else { return }
        profilePersistenceTask?.cancel()
        profilePersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.persistCurrentWorkspaceProfile()
        }
    }

    private func persistCurrentWorkspaceProfile() {
        // Before the agent reports a session, workspacePath falls back to the
        // home directory — which must never be recorded as a real workspace.
        guard sessionInfo != nil else { return }
        let path = workspacePath
        let profile = WorkspaceProfile(
            path: path,
            lastOpened: Date(),
            model: selectedModel,
            accountID: settings.activeAccountID,
            mode: selectedMode,
            previewURL: settings.previewURL,
            contextFiles: contextFiles,
            draft: draftText
        )
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            workspaceProfiles[index] = profile
        } else {
            workspaceProfiles.append(profile)
        }
        workspaceProfiles.sort { $0.lastOpened > $1.lastOpened }
        persistWorkspaceProfiles()
    }

    private func persistWorkspaceProfiles() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(workspaceProfiles) {
            UserDefaults.standard.set(data, forKey: "Locus.workspaceProfiles")
        }
    }

    private func recordPrompt(_ text: String) {
        promptHistory.removeAll { $0 == text }
        promptHistory.insert(text, at: 0)
        promptHistory = Array(promptHistory.prefix(50))
        promptHistoryCursor = nil
        if persistenceEnabled {
            UserDefaults.standard.set(promptHistory, forKey: "Locus.promptHistory")
        }
    }

    private func rebalanceContextBudget() {
        var used = 0
        var excluded = 0
        for index in contextFiles.indices where contextFiles[index].isIncluded {
            guard contextFiles[index].isAvailable else {
                contextFiles[index].isIncluded = false
                continue
            }
            let tokens = contextFiles[index].estimatedTokens
            if used + tokens > contextBudgetTokens {
                contextFiles[index].isIncluded = false
                excluded += 1
            } else {
                used += tokens
            }
        }
        if excluded > 0 {
            contextNotice = "\(excluded) file\(excluded == 1 ? "" : "s") excluded to preserve model response space."
        } else if used >= Int(Double(contextBudgetTokens) * 0.8) {
            contextNotice = "Context pack is near its \(contextBudgetTokens.formatted()) token budget."
        }
    }

    private func transcriptContext(from blocks: [ChatBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block.kind {
            case .user: "User: \(block.text)"
            case .assistant: "Assistant: \(block.text)"
            case .note: block.completion == nil ? "Note: \(block.text)" : nil
            case .tool, .error: nil
            }
        }
        .suffix(12)
        .joined(separator: "\n\n")
    }

    private func seedUITestState() {
        // A fixed path so UI tests see a deterministic workspace name ("tmp")
        // regardless of the runner's TMPDIR.
        let workspace = "/tmp"
        agentRuntimePhase = .online
        modelRuntimePhase = .online
        // The suite's inspector tests assume the panel starts open; the
        // collapsed default is covered by a settings unit test instead.
        inspectorCollapsed = false
        models = [
            ModelInfo(
                name: "qwen3:8b",
                size: 8_000_000_000,
                parameterSize: "8B",
                contextLength: 32_768
            ),
        ]
        // The picker reads the local list, which a live refresh would normally
        // fill in.
        localModels = models
        sessionInfo = SessionInfo(
            model: "qwen3:8b",
            host: "http://localhost:11434",
            cwd: workspace,
            session: "\(workspace)/seed-current.jsonl",
            sessionID: "seed-current",
            messages: 3,
            approxTokens: 42,
            promptTokens: 20,
            completionTokens: 22,
            contextLimit: 32_768,
            maxIterations: 40,
            hasProjectContext: false,
            provider: "ollama",
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
        currentSessionID = "seed-current"
        sessions = [
            SessionSummary(
                id: "seed-current",
                name: "seed-current.jsonl",
                preview: "Review the workspace",
                mtime: Date().timeIntervalSince1970,
                size: 400,
                title: "Workspace review",
                pinned: true,
                cwd: workspace
            ),
            SessionSummary(
                id: "seed-archived",
                name: "seed-archived.jsonl",
                preview: "Archived design pass",
                mtime: Date().addingTimeInterval(-600).timeIntervalSince1970,
                size: 300,
                archived: true,
                cwd: workspace
            ),
        ]
        expandedWorkspaceIDs = [SessionSummary.canonicalWorkspacePath(workspace)]
        blocks = [
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                kind: .user,
                text: "Review the workspace"
            ),
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                kind: .assistant,
                text: "The workspace is ready for a focused review."
            ),
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
                kind: .note,
                completion: TurnCompletion(
                    outcome: .complete,
                    mode: .build,
                    durationMilliseconds: 84_000
                )
            ),
        ]
        promptHistory = ["Audit the current changes", "Review the workspace"]

        // The three newest inspector tabs read from state the agent normally
        // fills in. Without seeds they render their empty states and nothing
        // about them is assertable.
        isGitRepository = true
        gitBranch = "main"
        gitChanges = [
            GitChange(
                path: "Locus/AppModel.swift",
                status: .modified,
                staged: false,
                unstaged: true,
                additions: 12,
                deletions: 3
            ),
            GitChange(
                path: "Locus/InspectorView.swift",
                status: .modified,
                staged: true,
                unstaged: false,
                additions: 40,
                deletions: 120
            ),
            GitChange(
                path: "docs/console.md",
                status: .untracked,
                staged: false,
                unstaged: true
            ),
        ]
        indexedWorkspacePath = workspace
        workspaceFileIndex = [
            "README.md",
            "Locus/AppModel.swift",
            "Locus/InspectorView.swift",
            "Locus/TerminalSession.swift",
            "docs/console.md",
        ].map { URL(fileURLWithPath: workspace).appending(path: $0) }
        agentInstructionsExists = true
        savedAgentInstructions = "# Workspace instructions\n\n- Keep changes focused.\n"
        agentInstructionsDraft = savedAgentInstructions
        terminal.handle([
            "type": "terminal_output",
            "text": "On branch main\nnothing to commit, working tree clean\n",
        ])

        workspaceProfiles = [
            WorkspaceProfile(
                path: workspace,
                lastOpened: Date(),
                model: "qwen3:8b",
                accountID: nil,
                mode: .build,
                previewURL: "http://localhost:3000",
                contextFiles: [],
                draft: ""
            ),
        ]

        // Opt-in, not part of the base fixture: a pending permission disables
        // send and clear-chat globally, which would break every other UI test.
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_PERMISSION"] == "1" {
            blocks.append(ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                kind: .tool,
                tool: ToolPayload(
                    toolID: "seed-tool-permission",
                    tool: "bash",
                    summary: "$ rm -rf build",
                    detail: "rm -rf build",
                    status: .awaitingPermission,
                    requestID: "req-ui-1"
                )
            ))
        }
    }

    private func showToast(
        _ message: String,
        actionTitle: String? = nil,
        duration: Double = 2.4
    ) {
        toastTask?.cancel()
        if actionTitle == nil { pendingDeletedChat = nil }
        toast = AppToast(
            message: message,
            actionTitle: actionTitle
        )
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.pendingDeletedChat = nil
        }
    }

    private func persistExpandedWorkspaces() {
        guard persistenceEnabled else { return }
        UserDefaults.standard.set(
            expandedWorkspaceIDs.sorted(),
            forKey: "Locus.expandedWorkspaces"
        )
    }

    private func persistSettings() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "Locus.settings")
        }
    }

    private func persistCheckpoints() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(checkpoints) {
            UserDefaults.standard.set(data, forKey: "Locus.checkpoints")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func readChatAttachments(
        _ selected: [URL],
        excluding existing: Set<URL>
    ) -> ChatAttachmentLoadResult {
        let directImageTypes = [
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
        ]
        var attachments: [ChatAttachment] = []
        var unsupported = 0
        var oversized = 0
        var unreadable = 0
        var truncatedPDFs = 0
        var totalImageBytes = 0
        var totalTextBytes = 0

        for selectedURL in selected {
            let url = selectedURL.standardizedFileURL
            guard !existing.contains(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else {
                unsupported += 1
                continue
            }
            let size = values?.fileSize ?? 0
            let ext = url.pathExtension.lowercased()

            if ext == "pdf" {
                guard size <= 10_000_000, totalTextBytes < 750_000 else {
                    oversized += 1
                    continue
                }
                guard let document = PDFDocument(url: url),
                      let rawText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawText.isEmpty
                else {
                    unreadable += 1
                    continue
                }
                let remaining = max(750_000 - totalTextBytes, 0)
                let content = String(rawText.prefix(min(500_000, remaining)))
                if content.count < rawText.count { truncatedPDFs += 1 }
                totalTextBytes += content.utf8.count
                attachments.append(
                    ChatAttachment(url: url, kind: .text, textContent: content)
                )
                continue
            }

            let type = UTType(filenameExtension: ext)
            if type?.conforms(to: .image) == true {
                guard size <= 15_000_000, totalImageBytes < 25_000_000 else {
                    oversized += 1
                    continue
                }
                let imageData: Data?
                let mimeType: String?
                if let directMIME = directImageTypes[ext] {
                    imageData = try? Data(contentsOf: url, options: .mappedIfSafe)
                    mimeType = directMIME
                } else if let image = NSImage(contentsOf: url),
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let jpeg = bitmap.representation(
                              using: .jpeg,
                              properties: [.compressionFactor: 0.88]
                          ) {
                    imageData = jpeg
                    mimeType = "image/jpeg"
                } else {
                    imageData = nil
                    mimeType = nil
                }
                guard let imageData, let mimeType,
                      imageData.count <= 15_000_000,
                      totalImageBytes + imageData.count <= 25_000_000
                else {
                    unreadable += 1
                    continue
                }
                totalImageBytes += imageData.count
                attachments.append(
                    ChatAttachment(
                        url: url,
                        kind: .image,
                        imageData: imageData,
                        mimeType: mimeType
                    )
                )
                continue
            }

            if ContextFileTypes.allowedExtensions.contains(ext)
                || type?.conforms(to: .text) == true {
                guard size <= 500_000,
                      totalTextBytes + size <= 750_000
                else {
                    oversized += 1
                    continue
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let content = String(data: data, encoding: .utf8),
                      !content.isEmpty
                else {
                    unreadable += 1
                    continue
                }
                totalTextBytes += data.count
                attachments.append(
                    ChatAttachment(url: url, kind: .text, textContent: content)
                )
                continue
            }

            unsupported += 1
        }

        var warnings: [String] = []
        if unsupported > 0 { warnings.append("\(unsupported) unsupported") }
        if oversized > 0 { warnings.append("\(oversized) over the size limit") }
        if unreadable > 0 { warnings.append("\(unreadable) unreadable") }
        if truncatedPDFs > 0 { warnings.append("\(truncatedPDFs) PDF truncated") }
        let notice = warnings.isEmpty ? nil : "Skipped or limited: \(warnings.joined(separator: ", "))."
        return ChatAttachmentLoadResult(attachments: attachments, notice: notice)
    }

    nonisolated private static func readContextSelection(
        _ selected: [URL],
        excluding existing: Set<URL>,
        limit: Int
    ) -> ContextLoadResult {
        guard limit > 0 else {
            return ContextLoadResult(files: [], notice: "Context packs support up to 50 files.")
        }
        let urls = expandedContextURLs(selected, limit: limit)
        var files: [ContextFile] = []
        var oversized = 0
        var unreadable = 0
        var overPackBudget = 0
        var totalBytes = 0

        for url in urls where files.count < limit {
            let normalized = url.standardizedFileURL
            guard !existing.contains(normalized) else { continue }
            let values = try? normalized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            guard size <= 256_000 else {
                oversized += 1
                continue
            }
            guard totalBytes + size <= 1_000_000 else {
                overPackBudget += 1
                continue
            }
            guard let data = try? Data(contentsOf: normalized, options: .mappedIfSafe),
                  let content = String(data: data, encoding: .utf8)
            else {
                unreadable += 1
                continue
            }
            totalBytes += data.count
            files.append(
                ContextFile(
                    url: normalized,
                    content: content,
                    modificationDate: values?.contentModificationDate
                )
            )
        }

        var warnings: [String] = []
        if oversized > 0 {
            warnings.append("\(oversized) oversized")
        }
        if unreadable > 0 {
            warnings.append("\(unreadable) binary or unreadable")
        }
        if overPackBudget > 0 {
            warnings.append("\(overPackBudget) over the 1 MB pack limit")
        }
        if urls.count == limit {
            warnings.append("selection capped at 50 text files")
        }
        let notice = warnings.isEmpty ? nil : "Skipped: \(warnings.joined(separator: ", "))."
        return ContextLoadResult(files: files, notice: notice)
    }

    nonisolated private static func reloadContextReference(_ reference: ContextFile) -> ContextFile {
        let url = reference.url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                issue: "File is missing"
            )
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (values?.fileSize ?? 0) <= 256_000 else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                modificationDate: values?.contentModificationDate,
                issue: "File is larger than 256 KB"
            )
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8)
        else {
            return ContextFile(
                id: reference.id,
                url: url,
                isIncluded: false,
                modificationDate: values?.contentModificationDate,
                issue: "File is unreadable or not UTF-8 text"
            )
        }
        return ContextFile(
            id: reference.id,
            url: url,
            content: content,
            isIncluded: reference.isIncluded,
            modificationDate: values?.contentModificationDate
        )
    }

    nonisolated private static func expandedContextURLs(_ selected: [URL], limit: Int) -> [URL] {
        var output: [URL] = []

        for url in selected where output.count < limit {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                output.append(url)
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let child as URL in enumerator {
                if ContextFileTypes.skippedDirectories.contains(child.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard output.count < limit,
                      ContextFileTypes.allowedExtensions.contains(child.pathExtension.lowercased()),
                      (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                output.append(child)
            }
        }
        return output
    }

    nonisolated private static func exportMarkdown(
        session: SessionSummary,
        messages: [HistoryMessage],
        workspace: String?,
        model: String?,
        started: String?
    ) -> String {
        var lines = [
            "# \(session.displayTitle)",
            "",
            "- Exported: \(Date().formatted(date: .abbreviated, time: .shortened))",
            "- Started: \(started?.nilIfEmpty ?? session.date.formatted(date: .abbreviated, time: .shortened))",
            "- Model: \(model?.nilIfEmpty ?? "Unknown")",
            "- Workspace: `\(workspace?.nilIfEmpty ?? "Unknown")`",
            "- Session: `\(session.id)`",
            "",
        ]
        for message in messages {
            switch message.role {
            case "user":
                lines.append("## You\n\n\(displayUserText(message.content))\n")
            case "assistant":
                lines.append("## Locus\n\n\(message.content)\n")
            case "tool":
                lines.append("### Tool: \(message.name ?? "tool")\n\n```\n\(message.content)\n```\n")
            default:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func safeFilename(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(
            of: #"[^a-zA-Z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
            .nilIfEmpty ?? "locus-session"
    }

    nonisolated private static func displayUserText(_ content: String) -> String {
        guard let range = content.range(of: "User request:\n", options: .backwards) else {
            return content
        }
        return String(content[range.upperBound...])
    }

    private static func blocks(from messages: [HistoryMessage]) -> [ChatBlock] {
        messages.compactMap { message in
            switch message.role {
            case "user":
                ChatBlock(kind: .user, text: displayUserText(message.content))
            case "assistant" where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(message.reasoning?.isEmpty ?? true):
                ChatBlock(
                    kind: .assistant,
                    text: message.content,
                    reasoningText: message.reasoning
                )
            case "tool":
                ChatBlock(
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: UUID().uuidString,
                        tool: message.name ?? "tool",
                        summary: message.name ?? "tool",
                        detail: "",
                        status: .done,
                        result: message.content
                    )
                )
            default:
                nil
            }
        }
    }

}

extension AppModel: TerminalTransport {
    /// The console speaks over the same socket as the chat. The Bool is
    /// checked by callers so a dropped command is reported, never silent.
    @discardableResult
    func sendTerminal(_ payload: [String: Any]) -> Bool {
        backend.send(payload)
    }
}

enum CommandAction: String, CaseIterable, Identifiable {
    case newSession
    case clearChat
    case clearSessions
    case reviewChanges
    case createCheckpoint
    case askMode
    case workMode
    case planMode
    case buildMode
    case chooseWorkspace
    case newWorkspace
    case browseModels
    case refreshModels
    case exportSession
    case permissions
    case showShortcuts
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "Start a new session"
        case .clearChat: "Clear chat"
        case .clearSessions: "Clear saved sessions"
        case .reviewChanges: "Review file changes"
        case .createCheckpoint: "Create a session checkpoint"
        case .askMode: "Turn on Just Chat"
        case .workMode: "Use adaptive Work mode"
        case .planMode: "Switch to Plan mode"
        case .buildMode: "Switch to Build mode"
        case .chooseWorkspace: "Choose a workspace"
        case .newWorkspace: "Create a new workspace folder"
        case .browseModels: "Browse Hugging Face models"
        case .refreshModels: "Refresh installed models"
        case .exportSession: "Export current session as Markdown"
        case .permissions: "Change what the agent may do without asking"
        case .showShortcuts: "Show keyboard shortcuts"
        case .openSettings: "Open Settings"
        }
    }

    var symbol: String {
        switch self {
        case .newSession: "plus"
        case .clearChat: "eraser"
        case .clearSessions: "trash"
        case .reviewChanges: "doc.text.magnifyingglass"
        case .createCheckpoint: "clock.arrow.circlepath"
        case .askMode: "bubble.left"
        case .workMode: "sparkles"
        case .planMode: "list.bullet.clipboard"
        case .buildMode: "hammer"
        case .chooseWorkspace: "folder"
        case .newWorkspace: "folder.badge.plus"
        case .browseModels: "shippingbox.and.arrow.backward"
        case .refreshModels: "arrow.clockwise"
        case .exportSession: "square.and.arrow.up"
        case .permissions: "shield.lefthalf.filled"
        case .showShortcuts: "keyboard"
        case .openSettings: "gearshape"
        }
    }

    var shortcut: String {
        switch self {
        case .newSession: "⌘N"
        case .clearChat: "⌘⇧K"
        case .clearSessions: ""
        case .reviewChanges: "⌘R"
        case .createCheckpoint: "⌘S"
        case .askMode: "⌥A"
        case .workMode: "⌥W"
        case .planMode: "⌥P"
        case .buildMode: "⌥B"
        case .showShortcuts: "⌘/"
        case .chooseWorkspace, .newWorkspace, .browseModels, .refreshModels,
             .exportSession, .permissions, .openSettings: ""
        }
    }
}

@MainActor
private final class DisplaySynchronizedFlushDriver: NSObject {
    private let callback: () -> Void
    private var displayLink: CADisplayLink?
    private var pending = false

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func request() {
        guard !pending else { return }
        pending = true
        if displayLink == nil,
           let source = NSApplication.shared.keyWindow?.screen ?? NSScreen.main
        {
            let link = source.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        if let displayLink {
            displayLink.isPaused = false
        } else {
            DispatchQueue.main.async { [weak self] in self?.fire() }
        }
    }

    func cancelPending() {
        pending = false
        displayLink?.isPaused = true
    }

    func invalidate() {
        pending = false
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        fire()
    }

    private func fire() {
        guard pending else { return }
        pending = false
        displayLink?.isPaused = true
        callback()
    }
}

private struct ModelsResponse: Codable {
    let models: [ModelInfo]
    let current: String
}

private struct SessionsResponse: Codable {
    let sessions: [SessionSummary]
    let current: String
}

private struct NewSessionResponse: Codable {
    let ok: Bool
    let reason: String
    let sessionInfo: SessionInfo

    enum CodingKeys: String, CodingKey {
        case ok, reason
        case sessionInfo = "session_info"
    }
}

private struct ClearSessionsResponse: Codable {
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

private struct DeleteSessionResponse: Codable {
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

private struct RestoreSessionsResponse: Codable {
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

private struct DeletedChatUndo {
    let session: SessionSummary
    let trashBatch: String
    let wasActive: Bool
}

private struct ResumeResponse: Codable {
    let ok: Bool
    let text: String
    let messages: [HistoryMessage]
    let sessionInfo: SessionInfo

    enum CodingKeys: String, CodingKey {
        case ok, text, messages
        case sessionInfo = "session_info"
    }
}

private struct SessionDetailResponse: Codable {
    let id: String
    let messages: [HistoryMessage]
    let preview: String
    let title: String?
    let pinned: Bool?
    let archived: Bool?
    let cwd: String?
    let model: String?
    let started: String?
}

private struct ContextLoadResult: Sendable {
    let files: [ContextFile]
    let notice: String?
}

private struct ChatAttachmentLoadResult: Sendable {
    let attachments: [ChatAttachment]
    let notice: String?
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
