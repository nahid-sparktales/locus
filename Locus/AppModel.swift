import AppKit
import Combine
import Foundation
import PDFKit
import QuartzCore
import UniformTypeIdentifiers
import UserNotifications

struct AppLifecycleRunSnapshot: Codable, Equatable {
    let sessionID: String
    let runID: String
    let state: TeamRunState
    let updatedAt: Date
}

struct AppLifecycleRecovery: Equatable {
    let snapshot: AppLifecycleRunSnapshot?

    var message: String {
        guard let snapshot else {
            return "Locus did not close normally. Your last session was restored."
        }
        switch snapshot.state {
        case .completed:
            return "Locus was force quit after the team run completed. Its results were restored."
        case .failed, .cancelled, .discarded:
            return "Locus did not close normally. The last team run finished as \(snapshot.state.title.lowercased())."
        case .interrupted:
            return "Locus closed unexpectedly. The interrupted team run is ready to resume."
        case .queued, .dispatching, .running, .waitingPermission, .waitingComputer,
             .waitingDispatchApproval, .reviewing, .paused:
            return "Locus closed unexpectedly. The last team run can be inspected and resumed."
        }
    }
}

/// A deliberately tiny crash journal. The durable session/run database remains
/// authoritative; these defaults only tell the next launch what to reopen and
/// whether the previous process reached its ordinary termination hook.
final class AppLifecycleJournal {
    private let defaults: UserDefaults
    private let cleanKey: String
    private let snapshotKey: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "Locus.lifecycle") {
        self.defaults = defaults
        cleanKey = "\(keyPrefix).clean"
        snapshotKey = "\(keyPrefix).latestRun"
    }

    @discardableResult
    func beginLaunch() -> AppLifecycleRecovery? {
        let hadPreviousLaunch = defaults.object(forKey: cleanKey) != nil
        let previousLaunchWasClean = defaults.bool(forKey: cleanKey)
        let snapshot = defaults.data(forKey: snapshotKey)
            .flatMap { try? JSONDecoder().decode(AppLifecycleRunSnapshot.self, from: $0) }
        // Set this before any services are started. Force Quit cannot run a
        // callback, so leaving this false is the abnormal-exit signal.
        defaults.set(false, forKey: cleanKey)
        guard hadPreviousLaunch, !previousLaunchWasClean else { return nil }
        return AppLifecycleRecovery(snapshot: snapshot)
    }

    func record(sessionID: String, runID: String, state: TeamRunState, at date: Date = Date()) {
        guard !sessionID.isEmpty, !runID.isEmpty else { return }
        let snapshot = AppLifecycleRunSnapshot(
            sessionID: sessionID,
            runID: runID,
            state: state,
            updatedAt: date
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    func markCleanExit() {
        defaults.set(true, forKey: cleanKey)
    }
}

struct AutomaticInspectorPrompt: Equatable {
    let tab: InspectorTab
    let runID: String?

    var isTeamRun: Bool { tab == .runs }

    var title: String {
        isTeamRun
            ? "Open Team Runs for team requests?"
            : "Open Context & Plan for solo requests?"
    }

    var message: String {
        if isTeamRun {
            return "Locus can open Team Runs whenever you send a team request so you can follow its agents and progress. You can change this anytime in Settings → General → Conversation."
        }
        return "Locus can open Context & Plan whenever you send a solo Work request so you can follow context use and the current plan. You can change this anytime in Settings → General → Conversation."
    }

    var confirmationTitle: String {
        isTeamRun ? "Open Team Runs Every Time" : "Open Context & Plan Every Time"
    }
}

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
    @Published private(set) var chatGPTAccount: ChatGPTAccountResponse?
    @Published private(set) var chatGPTUsage: ChatGPTUsageResponse?
    @Published private(set) var chatGPTLoginID: String?
    @Published private(set) var primaryAgentBehavior = AgentBehavior.primaryDefault()
    @Published private(set) var agentProfiles: [AgentProfile] = []
    @Published private(set) var agentTeams: [AgentTeam] = []
    @Published private(set) var teamRoutingConsentAccountIDs: Set<UUID> = []
    @Published var globalAgentConcurrency = 3 {
        didSet {
            let bounded = min(max(globalAgentConcurrency, 1), 8)
            if bounded != globalAgentConcurrency {
                globalAgentConcurrency = bounded
                return
            }
            if persistenceEnabled {
                UserDefaults.standard.set(bounded, forKey: AgentTeamStore.globalConcurrencyKey)
            }
        }
    }
    @Published var selectedAgentTeamID: UUID? = nil {
        didSet {
            guard persistenceEnabled else { return }
            UserDefaults.standard.set(selectedAgentTeamID?.uuidString, forKey: AgentTeamStore.selectionKey)
        }
    }
    @Published private(set) var orchestrationRunID: String?
    @Published private(set) var orchestrationState: TeamRunState?
    @Published private(set) var activeWorkerID: String?
    @Published private(set) var taskConversationStates: [String: TaskConversationState] = [:]
    @Published private(set) var dispatcherActivity: AgentActivity?
    @Published private(set) var dispatcherValidationReason: String?
    @Published private(set) var agentActivities: [AgentActivity] = []
    @Published private(set) var teamModelCalls = 0
    @Published private(set) var teamMeteredTokens = 0
    @Published private(set) var activeTaskRecord: TaskRecord?
    @Published private(set) var taskHasChanges = false
    @Published private(set) var taskPatchBytes = 0
    @Published private(set) var orchestrationRuns: [OrchestrationRun] = []
    @Published private(set) var selectedOrchestrationRun: OrchestrationRun?
    @Published private(set) var orchestrationEvents: [OrchestrationEvent] = []
    @Published private(set) var isLoadingOrchestrationRuns = false
    @Published private(set) var pendingDispatchPlan: DispatchPlan?
    @Published private(set) var evaluationSuites: [EvaluationSuite] = []
    @Published private(set) var activeEvaluationID: String?
    @Published private(set) var evaluationStatus: String?
    @Published private(set) var knowledgeStatus: WorkspaceKnowledgeStatus?
    @Published private(set) var workspaceMemories: [WorkspaceMemory] = []
    @Published private(set) var memoryCandidates: [WorkspaceMemory] = []
    @Published private(set) var memoryVaultStatus: MemoryVaultStatus?
    @Published private(set) var backgroundServices: [BackgroundServiceRecord] = []
    private var backgroundServicesRefreshGeneration = 0
    @Published var mcpInputRequest: MCPInputRequest?
    private var orchestrationEventIDs: Set<String> = []
    @Published var sessions: [SessionSummary] = []
    @Published var currentSessionID = ""
    @Published var sessionInfo: SessionInfo? {
        didSet {
            // Session changes must retarget the app-owned PTY even when its
            // inspector tab is hidden. Ignore a transient nil while the local
            // backend reconnects so the shell survives agent restarts.
            guard let cwd = sessionInfo?.cwd, !cwd.isEmpty else { return }
            terminal.configure(
                workspacePath: cwd,
                shell: settings.terminalShell,
                loginShell: settings.terminalLoginShell
            )
        }
    }
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
            // Zoom is a state of the *open* panel; closing it always lands
            // back in the rail, never in a hidden-but-zoomed limbo.
            if inspectorCollapsed { setInspectorZoomed(false) }
        }
    }
    @Published private(set) var inspectorWidth: CGFloat = CGFloat(AppSettings.defaultInspectorWidth)
    /// The panel filling the window with chat squeezed to a column. A focus
    /// mode, deliberately not persisted — relaunch returns to the normal
    /// layout. Only `setInspectorZoomed(_:)` may change it.
    @Published private(set) var inspectorZoomed = false
    /// The chat column's width while zoomed. The panel takes the remainder,
    /// so this is the value the divider drags in that state.
    @Published private(set) var zoomedChatWidth: CGFloat = CGFloat(AppSettings.defaultZoomedChatWidth)
    /// Whether un-zooming should reopen the session sidebar it auto-collapsed.
    private var restoreSidebarAfterZoom = false
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
    @Published private(set) var selectedChangeParsedDiff: ParsedFileDiff?
    @Published var selectedChangeShowsStaged = false
    @Published private(set) var gitUpstream: String?
    @Published private(set) var gitAhead = 0
    @Published private(set) var gitBehind = 0
    @Published private(set) var gitDetached = false
    @Published private(set) var gitHasCommits = true
    @Published private(set) var localBranches: [String] = []
    @Published var pendingHunkDiscard: DiffHunk?
    @Published private(set) var isSyncingRemote = false
    /// Whether origin looked like GitHub at the last check. Shows or hides
    /// the PR button; the action itself re-reads the remote at click time.
    @Published private(set) var originIsGitHub = false
    private var originCheckedForWorkspace: String?
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
    /// A settings-window-only appearance override. It drives every scene while
    /// the picker is being edited without writing the draft to disk.
    @Published private(set) var appearancePreview: AppAppearance?
    var effectiveAppearance: AppAppearance {
        appearancePreview ?? settings.resolvedAppearance
    }
    @Published var settingsPresented = false
    @Published private(set) var automaticInspectorPrompt: AutomaticInspectorPrompt?
    @Published var usageDashboardPresented = false
    @Published var usageSummary: UsageSummary?
    @Published var settingsPage: SettingsPage = .general
    @Published var modelLibraryPresented = false
    private var modelLibraryPendingSettingsDismissal = false
    @Published var commandPalettePresented = false
    @Published var checkpointPresented = false
    @Published var clearChatConfirmationPresented = false
    @Published var clearSessionsConfirmationPresented = false
    @Published var isClearingSessions = false
    @Published var showArchivedSessions = false
    @Published var searchQuery = "" {
        didSet { scheduleTranscriptHitSearch() }
    }
    @Published var transcriptHits: [TranscriptSearchHit] = []
    @Published var isSearchingTranscripts = false
    @Published var transcriptSearchIndexing = false
    @Published var sidebarSearchFocusToken = UUID()
    private var transcriptHitsTask: Task<Void, Never>?
    private var pendingSearchHit: TranscriptSearchHit?
    @Published var expandedWorkspaceIDs: Set<String> = []
    @Published var transcriptSearchPresented = false
    @Published var transcriptSearchQuery = "" {
        didSet { transcriptSearchSelection = 0 }
    }
    @Published var transcriptSearchSelection = 0
    @Published var streamRevision = 0
    @Published var toast: AppToast?
    var toastMessage: String? { toast?.message }
    @Published private(set) var lifecycleRecoveryMessage: String?
    @Published var backendLogHint = ""
    @Published var contextNotice: String?
    @Published var isLoadingContext = false
    @Published private(set) var extensions = ExtensionsResponse.empty
    @Published private(set) var extensionCatalog: [ExtensionCatalogEntry] = []
    @Published private(set) var extensionTools: [ExtensionToolMetadata] = []
    @Published var extensionErrorMessage: String?
    @Published private(set) var isLoadingExtensions = false
    /// App-owned PTY state. A `let` on its own ObservableObject keeps terminal
    /// title/lifecycle publications from redrawing the conversation.
    let terminal = TerminalSession()
    let computerControl = ComputerControlService()
    /// The browser, for the same reason as the terminal: its tab list and load
    /// progress change far too often to republish AppModel over.
    let browser = BrowserService()
    let streamingReply = StreamingReplyState()

    private let backend: BackendService
    private let backendProcess = BackendProcess()
    private var taskWorkers: [String: TaskWorkerRuntime] = [:]
    /// Backends that refused the browser handshake because a turn was running.
    private var pendingBrowserCapabilityTransports: [BackendService] = []
    private var conversationBackend: BackendService {
        taskWorkers[currentSessionID]?.service ?? backend
    }

    /// Team chats execute in dedicated worker processes. Run controls must go
    /// back to the worker that owns the run; sending them to the main control
    /// service can update the shared run database without interrupting the
    /// model call, which makes a cancelled approval reappear on reconnect.
    private func orchestrationBackend(for runID: String) -> BackendService {
        guard let sessionID = Self.orchestrationOwnerSessionID(
            for: runID,
            currentSessionID: currentSessionID,
            currentRunID: orchestrationRunID,
            states: taskConversationStates
        ) else { return backend }
        return taskWorkers[sessionID]?.service ?? backend
    }

    static func orchestrationOwnerSessionID(
        for runID: String,
        currentSessionID: String,
        currentRunID: String?,
        states: [String: TaskConversationState]
    ) -> String? {
        if currentRunID == runID { return currentSessionID }
        return states.first(where: { $0.value.runID == runID })?.key
    }

    func teamRunPresentation(
        for runID: String,
        durable run: OrchestrationRun?
    ) -> TeamRunPresentation {
        Self.resolveTeamRunPresentation(
            runID: runID,
            currentRunID: orchestrationRunID,
            liveState: orchestrationState,
            isBusy: isBusy,
            durableState: run.flatMap { TeamRunState(rawValue: $0.state) },
            durableRecoverable: run?.recoverable == true
        )
    }

    static func resolveTeamRunPresentation(
        runID: String,
        currentRunID: String?,
        liveState: TeamRunState?,
        isBusy: Bool,
        durableState: TeamRunState?,
        durableRecoverable: Bool
    ) -> TeamRunPresentation {
        let isCurrent = currentRunID == runID
        let state = (isCurrent ? liveState : nil) ?? durableState ?? .dispatching
        let hasLiveOwner = isCurrent && isBusy && !state.isTerminal && state != .paused
        let hasRecoverableSavedState = durableRecoverable
            && (durableState == .paused || durableState == .interrupted)
        let canRecover = (!isCurrent || !isBusy)
            && hasRecoverableSavedState
            && (state == .paused || state == .interrupted)
        return TeamRunPresentation(
            state: state,
            isCurrent: isCurrent,
            isActivelyOwned: hasLiveOwner,
            canPause: hasLiveOwner && state != .waitingDispatchApproval,
            canStop: hasLiveOwner,
            canRecover: canRecover
        )
    }
    private let ollamaRuntime = OllamaRuntime()
    private let mcpAuthCoordinator = MCPAuthCoordinator()
    private let workspaceAccess: WorkspaceAccess
    private let knowledgeWatcher = WorkspaceKnowledgeWatcher()
    private var knowledgeReindexTask: Task<Void, Never>?
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
    private var turnDispatchedTeamRunID: String?
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
    private var orchestrationRunsTasks: [String: (generation: Int, task: Task<OrchestrationRunsResponse, Error>)] = [:]
    private var orchestrationDetailTasks: [String: Task<OrchestrationRun, Error>] = [:]
    private var orchestrationEventTasks: [String: Task<OrchestrationEventsResponse, Error>] = [:]
    private var orchestrationRunsGeneration = 0
    private var orchestrationSelectionGeneration = 0
    private var requestedOrchestrationRunID: String?
    private var requestedOrchestrationLoadKey: String?
    private var terminalRefreshRunIDs: Set<String> = []
    private let lifecycleJournal: AppLifecycleJournal?
    private var pendingLifecycleRecovery: AppLifecycleRecovery?
    private var indexedWorkspacePath: String?
    private var terminationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// False for unit and UI tests. Views check it before touching the
    /// credential file: a test must not read — or delete — the secrets of
    /// whoever is running the suite.
    let persistenceEnabled: Bool
    private let isUITesting: Bool
    private var isShuttingDown = false

    init(
        startImmediately: Bool = true,
        backendOverride: BackendService? = nil,
        lifecycleJournal: AppLifecycleJournal? = nil
    ) {
        let isUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"
        self.isUITesting = isUITesting
        persistenceEnabled = startImmediately && !isUITesting
        let launchJournal = lifecycleJournal ?? AppLifecycleJournal()
        self.lifecycleJournal = persistenceEnabled ? launchJournal : nil
        pendingLifecycleRecovery = persistenceEnabled ? launchJournal.beginLaunch() : nil
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
                    keeping: Set(accounts.map(\.credentialAccount))
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
        if !isUITesting, persistenceEnabled {
            primaryAgentBehavior = AgentTeamStore.loadPrimaryBehavior(from: defaults)
            let loadedProfiles = AgentTeamStore.loadProfiles(from: defaults)
            let storedTeams = AgentTeamStore.loadTeams(from: defaults)
            let approvalMigration = AgentTeamStore.migrateToOneTimeApproval(storedTeams)
            let budgetMigration = AgentTeamStore.migrateLegacyCallBudgets(approvalMigration.teams)
            let loadedTeams = budgetMigration.teams
            let loadedSelection = defaults.string(forKey: AgentTeamStore.selectionKey)
                .flatMap(UUID.init(uuidString:))
            agentProfiles = loadedProfiles
            agentTeams = loadedTeams
            if approvalMigration.changed || budgetMigration.changed {
                AgentTeamStore.save(profiles: loadedProfiles, teams: loadedTeams, to: defaults)
            }
            teamRoutingConsentAccountIDs = AgentTeamStore.loadConsent(from: defaults)
            let storedConcurrency = defaults.integer(forKey: AgentTeamStore.globalConcurrencyKey)
            globalAgentConcurrency = storedConcurrency == 0 ? 3 : min(max(storedConcurrency, 1), 8)
            selectedAgentTeamID = loadedTeams.contains(where: { $0.id == loadedSelection })
                ? loadedSelection : nil
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
        zoomedChatWidth = CGFloat(loadedSettings.inspectorZoomedChatWidth)
        inspectorCollapsed = loadedSettings.inspectorCollapsed
        sidebarCollapsed = loadedSettings.sidebarCollapsed
        let restoredInspectorTab = loadedSettings.resolvedInspectorTab
        inspectorTab = restoredInspectorTab.isWorkspaceTab
            ? restoredInspectorTab
            : loadedSettings.resolvedInspectorWorkspaceTab

        backend = backendOverride ?? BackendService(
            baseURL: URL(string: loadedSettings.backendURL) ?? URL(string: "http://127.0.0.1:8791")!
        )

        backend.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.agentRuntimePhase = .online
                    self.runtimeRecoveryAttempt = 0
                    self.sendComputerControlCapability()
                    self.browser.defaultViewport = self.settings.resolvedBrowserViewport.size
                    self.announceBrowserCapability()
                    self.syncPreferredPermissionMode(to: self.backend)
                    if let runID = self.orchestrationRunID {
                        Task { @MainActor [weak self] in
                            await self?.backfillOrchestrationEvents(runID)
                        }
                    }
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

        browser.onUserNotice = { [weak self] notice in
            self?.showToast(notice)
        }
        if startImmediately, !isUITesting {
            // Warm WebKit's helper processes once launch settles, so the
            // first page load doesn't pay their cold start. Gated on the
            // browser being enabled; the browser panel's onAppear re-arms
            // this if the user flips it on later.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.settings.browserEnabled else { return }
                self.browser.prewarm()
            }
        }

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
        if let team = selectedAgentTeam {
            let count = selectedTeamModelNames.count
            return "\(team.name) · \(count) \(count == 1 ? "model" : "models")"
        }
        guard let account = activeAccount else {
            return localModels.isEmpty && models.isEmpty ? "Auto" : selectedModel
        }
        return "\(account.shortName) · \(selectedModel)"
    }

    var selectedTeamModelNames: [String] {
        guard let team = selectedAgentTeam else { return [] }
        var seen: Set<String> = []
        return team.memberIDs.compactMap { id in
            guard let profile = agentProfiles.first(where: { $0.id == id }) else { return nil }
            let key = profile.model.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return profile.model
        }
    }

    var selectedTeamRouteIssue: String? {
        guard let team = selectedAgentTeam else { return nil }
        return AgentTeamValidation.routeErrors(
            team: team,
            profiles: agentProfiles,
            accounts: providerAccounts,
            accountModels: accountModels
        ).first
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

    var chatNavigationDisabled: Bool {
        (isBusy || hasPendingPermission) && taskWorkers[currentSessionID] == nil
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

    func teamRunState(for session: SessionSummary) -> TeamRunState? {
        if let state = taskConversationStates[session.id]?.state { return state }
        if session.id == currentSessionID, let orchestrationState { return orchestrationState }
        return session.task?.state
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
        if let orchestrationState, isBusy { return orchestrationState.title }
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

    // MARK: - Cross-session transcript search

    /// Debounced fetch behind the sidebar search field. Title filtering stays
    /// client-side and instant; transcript hits arrive from the agent's FTS
    /// index shortly after. An old agent (404) degrades to titles-only.
    private func scheduleTranscriptHitSearch() {
        transcriptHitsTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            transcriptHits = []
            isSearchingTranscripts = false
            transcriptSearchIndexing = false
            return
        }
        isSearchingTranscripts = true
        transcriptHitsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            let response = try? await backend.get(
                "/api/sessions/search",
                query: [
                    URLQueryItem(name: "query", value: query),
                    URLQueryItem(name: "limit", value: "20"),
                ],
                as: TranscriptSearchResponse.self
            )
            guard !Task.isCancelled else { return }
            isSearchingTranscripts = false
            transcriptSearchIndexing = response?.indexing ?? false
            transcriptHits = response?.results ?? []
        }
    }

    /// Open the hit's session and outline the matched message, reusing the
    /// in-conversation find for the scroll-and-outline work.
    func openSearchHit(_ hit: TranscriptSearchHit) {
        if hit.sessionID == currentSessionID {
            revealSearchHit(hit)
            return
        }
        guard let summary = sessions.first(where: { $0.id == hit.sessionID }) else {
            showToast("That conversation is no longer listed")
            return
        }
        pendingSearchHit = hit
        resume(summary)
    }

    func applyPendingSearchHitIfNeeded() {
        guard let hit = pendingSearchHit else { return }
        pendingSearchHit = nil
        // A resume that failed leaves the hit pending; a later unrelated
        // resume must not fire the find bar in whatever session it opened.
        guard hit.sessionID == currentSessionID else { return }
        revealSearchHit(hit)
    }

    private func revealSearchHit(_ hit: TranscriptSearchHit) {
        // The find bar needs a term that literally occurs in the block text;
        // the hit's own highlight is exactly that. Falling back to the typed
        // query keeps the flow alive if highlights are ever empty.
        let term = hit.firstMatchedTerm
            ?? searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        transcriptSearchQuery = term
        transcriptSearchPresented = true
        guard let block = blocks.first(where: { $0.historyIndex == hit.messageIndex })
        else { return }
        if let position = transcriptSearchMatches.firstIndex(of: block.id) {
            transcriptSearchSelection = position
        }
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
        await restoreAfterUncleanExitIfNeeded()
        requestNotificationAuthorization()
        startRuntimeMonitor()
    }

    private func restoreAfterUncleanExitIfNeeded() async {
        guard let recovery = pendingLifecycleRecovery else { return }
        pendingLifecycleRecovery = nil

        if let snapshot = recovery.snapshot {
            if currentSessionID != snapshot.sessionID,
               let session = sessions.first(where: { $0.id == snapshot.sessionID })
            {
                resume(session)
                // `resume` also serves ordinary UI actions and owns its Task.
                // Wait briefly for that existing path instead of duplicating
                // its transcript/workspace restoration logic here.
                for _ in 0..<50 {
                    guard currentSessionID != snapshot.sessionID else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if currentSessionID == snapshot.sessionID {
                await refreshOrchestrationRuns(
                    select: snapshot.runID,
                    terminal: snapshot.state == .completed
                        || snapshot.state == .failed
                        || snapshot.state == .cancelled
                        || snapshot.state == .discarded
                        || snapshot.state == .interrupted
                )
            }
        }

        let message = lifecycleRecoveryExplanation(fallback: recovery)
        if let run = selectedOrchestrationRun,
           teamRunPresentation(for: run.id, durable: run).canRecover
        {
            lifecycleRecoveryMessage = message
            showToast("A saved team run can be resumed", duration: 6)
        } else {
            // Terminal runs already have durable boards in the conversation.
            // Restoring one is normal data loading, not a warning condition.
            lifecycleRecoveryMessage = nil
        }
    }

    private func lifecycleRecoveryExplanation(fallback: AppLifecycleRecovery) -> String {
        guard let run = selectedOrchestrationRun else { return fallback.message }
        if run.state == TeamRunState.completed.rawValue {
            return "Locus was force quit after the team run completed. Its results were restored."
        }
        if teamRunPresentation(for: run.id, durable: run).canRecover {
            return "Locus closed unexpectedly. This team run can be resumed from its saved checkpoint."
        }
        if let state = TeamRunState(rawValue: run.state) {
            return "Locus did not close normally. The restored team run is \(state.title.lowercased())."
        }
        return fallback.message
    }

    func dismissLifecycleRecoveryMessage() {
        lifecycleRecoveryMessage = nil
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
        terminal.terminate()
        lifecycleJournal?.markCleanExit()
        // Zoom is transient and relaunch never restores it, so hand back the
        // room it borrowed before the layout is flushed to disk.
        setInspectorZoomed(false)
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
        knowledgeReindexTask?.cancel()
        knowledgeWatcher.stop()
        agentInstructionsTask?.cancel()
        orchestrationRunsTasks.values.forEach { $0.task.cancel() }
        orchestrationDetailTasks.values.forEach { $0.cancel() }
        orchestrationEventTasks.values.forEach { $0.cancel() }
        orchestrationRunsTasks.removeAll()
        orchestrationDetailTasks.removeAll()
        orchestrationEventTasks.removeAll()
        backend.disconnect()
        backendProcess.stop()
        taskWorkers.values.forEach { $0.stop() }
        taskWorkers.removeAll()
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

    private func watchWorkspaceKnowledge(_ root: String) {
        guard !isUITesting, !root.isEmpty else { return }
        knowledgeWatcher.start(path: root) { [weak self] in
            Task { @MainActor in self?.scheduleWorkspaceKnowledgeReindex(root) }
        }
        scheduleWorkspaceKnowledgeReindex(root, immediately: true)
    }

    private func scheduleWorkspaceKnowledgeReindex(
        _ root: String,
        immediately: Bool = false
    ) {
        knowledgeReindexTask?.cancel()
        knowledgeReindexTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(650)) }
            guard !Task.isCancelled, let self, self.workspacePath == root else { return }
            do {
                let _: WorkspaceKnowledgeStatus = try await self.backend.post(
                    "/api/knowledge/reindex",
                    body: ["workspace": root],
                    as: WorkspaceKnowledgeStatus.self
                )
                if self.settingsPage == .knowledge {
                    await self.refreshWorkspaceKnowledge()
                }
            } catch {
                // Search triggers a lazy first index too. Watcher failures must
                // never interrupt chat or workspace switching.
            }
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
        await migrateTerminalSettingsIfNeeded()

        do {
            let suffix = showArchivedSessions
                ? "?include_archived=true&limit=500"
                : "?limit=500"
            let response = try await backend.get("/api/sessions\(suffix)", as: SessionsResponse.self)
            sessions = response.sessions
            if taskWorkers[currentSessionID] == nil {
                currentSessionID = response.current
            }
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
        let credentialServerIDs = extensions.mcpServers
            .filter { $0.pluginID == id }
            .map(\.id)
        do {
            _ = try await backend.delete(
                "/api/extensions/plugins/\(id)",
                as: ExtensionOperationResponse.self
            )
            for serverID in credentialServerIDs {
                MCPCredentialStore.remove(serverID: serverID)
            }
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

    func materializeMCPPreset(
        _ preset: ExtensionMCPPreset,
        projectRef: String = ""
    ) async -> ExtensionMCPServer? {
        do {
            let server = try await backend.post(
                "/api/extensions/mcp/presets/materialize",
                body: ["id": preset.id, "project_ref": projectRef],
                as: ExtensionMCPServer.self
            )
            await refreshExtensions()
            return server
        } catch {
            extensionErrorMessage = error.localizedDescription
            return nil
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

    @discardableResult
    func testMCPServer(_ id: String) async -> Bool {
        do {
            let response = try await backend.post(
                "/api/extensions/mcp/test",
                body: ["id": id],
                timeout: 135,
                as: MCPTestResponse.self
            )
            await refreshExtensions()
            showToast(response.status?.state == "connected" ? "MCP server connected" : "MCP test finished")
            return response.status?.state == "connected"
        } catch {
            extensionErrorMessage = error.localizedDescription
            return false
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
            MCPCredentialStore.remove(serverID: id)
            await refreshExtensions()
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setMCPCredentials(serverID: String, values: [String: Any]) async -> Bool {
        guard JSONSerialization.isValidJSONObject(values) else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return false
        }
        let previous = MCPCredentialStore.get(serverID: serverID)
        guard MCPCredentialStore.set(values, serverID: serverID) else {
            extensionErrorMessage = "The MCP credentials could not be saved."
            return false
        }
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": Self.runtimeMCPCredentials(values)],
                as: MCPStatusCredentialResponse.self
            )
            await refreshExtensions()
            return true
        } catch {
            if let previous {
                MCPCredentialStore.set(previous, serverID: serverID)
            } else {
                MCPCredentialStore.remove(serverID: serverID)
            }
            extensionErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearMCPCredentials(serverID: String) async {
        do {
            _ = try await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": serverID, "credentials": [String: Any]()],
                as: MCPStatusCredentialResponse.self
            )
            MCPCredentialStore.remove(serverID: serverID)
            await refreshExtensions()
            showToast("MCP credentials removed")
        } catch {
            extensionErrorMessage = error.localizedDescription
        }
    }

    func authenticateMCPServer(
        _ server: ExtensionMCPServer,
        completion: ((Bool) -> Void)? = nil
    ) {
        mcpAuthCoordinator.authorize(server: server) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let values):
                Task {
                    let saved = await self.setMCPCredentials(serverID: server.id, values: values)
                    completion?(saved)
                }
            case .failure(let error):
                self.extensionErrorMessage = error.localizedDescription
                completion?(false)
            }
        }
    }

    private func restoreExtensionCredentials(for servers: [ExtensionMCPServer]) async {
        for server in servers {
            guard let storedValues = MCPCredentialStore.get(serverID: server.id) else { continue }
            guard Self.mcpCredentials(storedValues, areBoundTo: server) else {
                extensionErrorMessage = "Saved OAuth credentials no longer match \(server.name). Reconnect it before enabling the server."
                continue
            }
            let values = (try? await mcpAuthCoordinator.refreshedCredentialsIfNeeded(storedValues))
                ?? storedValues
            let oldData = try? JSONSerialization.data(withJSONObject: storedValues, options: [.sortedKeys])
            let refreshedData = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let refreshedToken = oldData != refreshedData
            if refreshedToken { MCPCredentialStore.set(values, serverID: server.id) }
            guard server.hasCredentials != true || refreshedToken else { continue }
            _ = try? await backend.post(
                "/api/extensions/mcp/credentials",
                body: ["id": server.id, "credentials": Self.runtimeMCPCredentials(values)],
                as: MCPStatusCredentialResponse.self
            )
        }
    }

    /// Never replay an issuer-bound access token after its user-editable MCP
    /// server has been pointed at a different resource or explicit issuer.
    /// Credentials written before issuer binding have neither field and remain
    /// available for the promised version-1 migration path.
    nonisolated static func mcpCredentials(
        _ values: [String: Any],
        areBoundTo server: ExtensionMCPServer
    ) -> Bool {
        if let resource = values["resource"] as? String {
            guard let rawURL = server.url,
                  var components = URLComponents(string: rawURL)
            else { return false }
            components.fragment = nil
            guard components.url?.absoluteString == resource else { return false }
        }
        if let issuer = values["issuer"] as? String,
           let configuredIssuer = server.oauth?.issuer,
           !configuredIssuer.isEmpty,
           issuer != configuredIssuer {
            return false
        }
        return true
    }

    /// Keep native-only registration and refresh material out of the Python
    /// runtime. It receives only what the active transport needs right now.
    nonisolated static func runtimeMCPCredentials(_ values: [String: Any]) -> [String: Any] {
        var runtime: [String: Any] = [:]
        for key in ["access_token", "headers", "env"] {
            if let value = values[key] { runtime[key] = value }
        }
        return runtime
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
        for account in due where account.kind == .chatGPT {
            do {
                let response = try await backend.get(
                    "/api/chatgpt/models",
                    as: ChatGPTModelsResponse.self
                )
                let names = response.models.map(\.id)
                accountModels[account.id] = names.isEmpty ? account.kind.curatedModels : names
                await refreshChatGPTAccount()
            } catch {
                accountModels[account.id] = account.kind.curatedModels
                accountStatus[account.id] = .runtimeUnavailable(error.localizedDescription)
            }
        }
        let endpointAccounts = due.filter { $0.kind != .chatGPT }
        await withTaskGroup(of: (UUID, ProviderModelCatalog.Result).self) { group in
            for account in endpointAccounts {
                group.addTask { (account.id, await ProviderModelCatalog.fetch(for: account)) }
            }
            for await (id, result) in group {
                guard let account = providerAccounts.first(where: { $0.id == id }) else {
                    continue
                }
                let routedModels = agentProfiles.compactMap { profile -> String? in
                    guard profile.route.accountID == id else { return nil }
                    return profile.model
                }
                let scoped = ProviderModelCatalog.scopedModels(
                    for: account,
                    result: result,
                    routedModels: routedModels
                )
                accountModels[id] = scoped
                accountStatus[id] = result.status
                if let replacement = scoped.first,
                   !scoped.contains(where: {
                       $0.caseInsensitiveCompare(account.preferredModel) == .orderedSame
                   }),
                   let index = providerAccounts.firstIndex(where: { $0.id == id })
                {
                    providerAccounts[index].preferredModel = replacement
                    persistProviderAccounts()
                }
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
        requeueingOnFailure: Bool = false,
        includeAttachments: Bool = true
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableAttachments = includeAttachments ? availableChatAttachments : []
        let hasChatAttachments = !availableAttachments.isEmpty
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
        let teamMention = TeamMentionResolver.selection(
            in: text,
            profiles: agentProfiles,
            teams: agentTeams
        )
        let wantsTeam = dispatchedMode != .ask
            && !isSlashPassthrough
            && (selectedAgentTeamID != nil || teamMention.agent != nil || teamMention.team != nil)
        let dispatchedTeam = wantsTeam ? teamManifest(for: text) : nil
        if wantsTeam, dispatchedTeam == nil { return }
        // Agent-side slash commands never receive attachments (the server
        // routes them past the turn machinery), so dispatching any would
        // silently drop them — keep the chips for the next real message.
        let dispatchedAttachments = isSlashPassthrough && dispatchedMode != .ask
            ? [] : availableAttachments
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
        turnDispatchedTeamRunID = dispatchedTeam?["run_id"] as? String
        Task { [weak self] in
            guard let self else { return }
            var transport = self.conversationBackend
            if dispatchedTeam != nil {
                guard let worker = await self.ensureTeamWorker(for: self.currentSessionID) else {
                    self.isBusy = false
                    self.turnStartedAt = nil
                    self.turnDispatchedMode = nil
                    self.turnDispatchedTeamRunID = nil
                    self.turnDispatchedInPlanMode = false
                    self.stashUnsent(
                        text,
                        requeue: requeueingOnFailure,
                        preserveDraft: preservingDraftOnFailure
                    )
                    return
                }
                transport = worker.service
            }
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
            if let agentConfig = encodedJSONObject(primaryAgentBehavior) {
                request["agent_config"] = agentConfig
            }
            if let dispatchedTeam { request["team"] = dispatchedTeam }
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
            guard transport.send(request) else {
                isBusy = false
                turnStartedAt = nil
                turnDispatchedMode = nil
                turnDispatchedTeamRunID = nil
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
            let teamRunID = (dispatchedTeam?["run_id"] as? String)?.nilIfEmpty
            blocks.append(ChatBlock(kind: .user, text: visibleText, teamRunID: teamRunID))
            if !text.isEmpty { recordPrompt(text) }
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            presentInspectorForSentRequest(isTeam: dispatchedTeam != nil, runID: teamRunID)
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
              conversationBackend.send(["type": "user_message", "text": text])
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
            if orchestrationState == .waitingDispatchApproval
                || steeringState?.hasPrefix("Stopping") == true
            {
                queueDraft()
            } else {
                steerDraft()
            }
        } else {
            send(draftText)
        }
    }

    /// Append the current direction to the active provider turn. The backend
    /// stops only the current generation, preserves completed tool results,
    /// and continues the same turn without an intermediate `turn_done`.
    func steerDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBusy,
              steeringState?.hasPrefix("Stopping") != true,
              !hasPendingPermission,
              !text.isEmpty
        else { return }
        guard conversationBackend.send(["type": "steer", "text": text]) else {
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
        guard conversationBackend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the active turn could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        // Scoped: only this conversation is being stopped; a background
        // worker's in-flight page action keeps its real outcome.
        browser.cancelPendingActions(ownedBy: currentSessionID)
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
        // A queued message was composed before any attachments added while it
        // waited; those belong to the user's next explicit send.
        send(
            queuedMessages.removeFirst(),
            preservingDraftOnFailure: false,
            requeueingOnFailure: true,
            includeAttachments: false
        )
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
        guard conversationBackend.send(["type": "retry_last"]) else {
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
        guard conversationBackend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the run could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        browser.cancelPendingActions(ownedBy: currentSessionID)
        pendingRetry = false
        steeringState = "Stopping the current run…"
        showToast("Stopping the current run")
    }

    var hasRunningWorkForQuit: Bool {
        terminal.hasForegroundJob || Self.shouldWarnBeforeQuit(
            isBusy: isBusy,
            hasPendingPermission: hasPendingPermission,
            currentSessionID: currentSessionID,
            orchestrationState: orchestrationState,
            taskConversationStates: taskConversationStates,
            liveWorkerSessionIDs: Set(
                taskWorkers.values.compactMap { runtime in
                    runtime.process.isRunning ? runtime.sessionID : nil
                }
            )
        )
    }

    /// A terminal durable run is authoritative for the current chat. Team
    /// workers intentionally remain alive between turns, so neither their
    /// process nor a stale pre-completion snapshot proves work is still active.
    static func shouldWarnBeforeQuit(
        isBusy: Bool,
        hasPendingPermission: Bool,
        currentSessionID: String,
        orchestrationState: TeamRunState?,
        taskConversationStates: [String: TaskConversationState],
        liveWorkerSessionIDs: Set<String>
    ) -> Bool {
        // These foreground flags are set synchronously when a new solo or team
        // turn begins, before a fresh orchestration event can replace the last
        // run's terminal state.
        if isBusy || hasPendingPermission {
            return true
        }
        if let orchestrationState, !orchestrationState.isTerminal {
            return true
        }
        let currentRunIsTerminal = orchestrationState?.isTerminal == true
        return taskConversationStates.contains { sessionID, snapshot in
            guard liveWorkerSessionIDs.contains(sessionID), !snapshot.state.isTerminal else {
                return false
            }
            // Completion events can arrive before older foreground flags and
            // task snapshots are cleared. Do not turn those stale values into
            // a destructive-looking quit confirmation.
            return sessionID != currentSessionID || !currentRunIsTerminal
        }
    }

    func stopRunningWorkForQuit(completion: @escaping @MainActor () -> Void) {
        terminal.terminate()
        for runtime in taskWorkers.values {
            _ = runtime.service.send(["type": "interrupt"])
        }
        _ = backend.send(["type": "interrupt"])
        computerControl.cancelPendingActions()
        browser.cancelPendingActions()
        Task { @MainActor in
            // Give every worker a bounded window to append its interrupted
            // task state and terminal event before shutdown stops processes.
            for _ in 0..<20 {
                if !hasRunningWorkForQuit { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            completion()
        }
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
        case .remember:
            if argument.isEmpty {
                settingsPage = .knowledge
                settingsPresented = true
            } else {
                rememberWorkspaceFact(
                    title: String(argument.prefix(80)), content: argument, tags: []
                )
            }
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
            guard conversationBackend.send([
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
        if orchestrationRunID != nil {
            orchestrationState = .running
            updateTaskConversation(state: .running, event: [:])
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
        guard modelBelongsToAccount(model, account: account) else { return }
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

    private func modelBelongsToAccount(_ model: String, account: ProviderAccount) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if account.kind != .custom {
            return ProviderModelFilter.matches(kind: account.kind, name: trimmed)
        }
        if case .connected = accountStatus[account.id],
           let reported = accountModels[account.id], !reported.isEmpty
        {
            return reported.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
        let routed = agentProfiles.filter { $0.route.accountID == account.id }.map(\.model)
        return routed.isEmpty || routed.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    // MARK: - Agents and teams

    var selectedAgentTeam: AgentTeam? {
        selectedAgentTeamID.flatMap { id in agentTeams.first(where: { $0.id == id }) }
    }

    var teamModeEnabled: Bool { selectedAgentTeam != nil }

    var shouldShowTeamDispatchProgress: Bool {
        isBusy && orchestrationRunID != nil && orchestrationState == .dispatching
            && pendingDispatchPlan == nil
    }

    var shouldShowTeamDispatchApproval: Bool {
        orchestrationState == .waitingDispatchApproval && pendingDispatchPlan != nil
    }

    var activeOrchestrationTeam: AgentTeam? {
        if let id = selectedOrchestrationRun?.teamID.flatMap(UUID.init(uuidString:)),
           let team = agentTeams.first(where: { $0.id == id })
        {
            return team
        }
        return selectedAgentTeam
    }

    func selectAgentTeam(_ id: UUID?) {
        selectedAgentTeamID = id
        showToast(id == nil ? "Solo mode" : "Team mode")
    }

    func savePrimaryAgentBehavior(_ behavior: AgentBehavior) {
        var updated = behavior
        updated.clamp()
        primaryAgentBehavior = updated
        if persistenceEnabled {
            AgentTeamStore.savePrimaryBehavior(updated)
        }
        showToast("Primary agent settings saved — they apply on the next turn")
    }

    func saveAgentProfile(_ profile: AgentProfile) {
        var updated = profile
        updated.clamp()
        guard updated.isConfigured else {
            showToast("Give the agent a name and exact model")
            return
        }
        let collision = agentProfiles.contains {
            $0.id != updated.id
                && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
        }
        guard !collision else {
            showToast("Agent names must be unique")
            return
        }
        if let index = agentProfiles.firstIndex(where: { $0.id == updated.id }) {
            agentProfiles[index] = updated
        } else {
            agentProfiles.append(updated)
        }
        persistAgentTeams()
        showToast("Saved \(updated.name)")
    }

    func removeAgentProfile(_ profile: AgentProfile) {
        guard !isBusy else {
            showToast("Stop the active run before removing an agent")
            return
        }
        agentProfiles.removeAll { $0.id == profile.id }
        agentTeams = agentTeams.compactMap { team in
            var updated = team
            updated.memberIDs.removeAll { $0 == profile.id }
            if updated.dispatcherID == profile.id { updated.dispatcherID = nil }
            if updated.fallbackDispatcherID == profile.id { updated.fallbackDispatcherID = nil }
            if updated.defaultWriterID == profile.id { updated.defaultWriterID = nil }
            return updated
        }
        if selectedAgentTeamID.flatMap({ id in agentTeams.first(where: { $0.id == id }) }) == nil {
            selectedAgentTeamID = nil
        }
        persistAgentTeams()
    }

    func saveAgentTeam(_ team: AgentTeam) {
        var updated = team
        updated.clamp()
        let errors = AgentTeamValidation.errors(team: updated, profiles: agentProfiles)
        guard errors.isEmpty else {
            showToast(errors[0])
            return
        }
        let collision = agentTeams.contains {
            $0.id != updated.id
                && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
        }
        guard !collision else {
            showToast("Team names must be unique")
            return
        }
        if let index = agentTeams.firstIndex(where: { $0.id == updated.id }) {
            agentTeams[index] = updated
        } else {
            agentTeams.append(updated)
        }
        persistAgentTeams()
        showToast("Saved \(updated.name)")
    }

    func removeAgentTeam(_ team: AgentTeam) {
        guard !isBusy else {
            showToast("Stop the active run before removing a team")
            return
        }
        agentTeams.removeAll { $0.id == team.id }
        if selectedAgentTeamID == team.id { selectedAgentTeamID = nil }
        persistAgentTeams()
    }

    func grantAutomaticRoutingConsent(for accountID: UUID) {
        teamRoutingConsentAccountIDs.insert(accountID)
        persistAgentTeams()
    }

    func revokeAutomaticRoutingConsent(for accountID: UUID) {
        teamRoutingConsentAccountIDs.remove(accountID)
        persistAgentTeams()
    }

    func testAgentProfileConnection(_ profile: AgentProfile) async -> String {
        switch profile.route {
        case .localOllama:
            guard let url = URL(string: lastOllamaHost + "/api/tags") else {
                return "The local Ollama URL is invalid."
            }
            do {
                let (data, response) = try await ProxyRuntime.shared.urlSession.data(from: url)
                guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1) else {
                    return "Ollama did not accept the connection."
                }
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let names = (object?["models"] as? [[String: Any]] ?? []).compactMap {
                    $0["name"] as? String
                }
                if !profile.model.isEmpty,
                   !names.contains(where: { $0.caseInsensitiveCompare(profile.model) == .orderedSame })
                {
                    return "Connected, but that exact model is not installed in Ollama."
                }
                return "Connected to local Ollama."
            } catch {
                return "Could not connect to Ollama: \(error.localizedDescription)"
            }
        case .providerAccount(let id):
            guard let account = providerAccounts.first(where: { $0.id == id }) else {
                return "That provider account is unavailable."
            }
            let result = await ProviderModelCatalog.fetch(for: account)
            accountModels[id] = result.models
            accountStatus[id] = result.status
            guard result.status.isHealthy else { return result.status.summary }
            if account.kind.listsModels,
               !profile.model.isEmpty,
               !result.models.contains(where: { $0.caseInsensitiveCompare(profile.model) == .orderedSame })
            {
                return "Connected, but the exact model was not in this account's catalog."
            }
            return result.status.summary
        }
    }

    private func persistAgentTeams() {
        guard persistenceEnabled else { return }
        AgentTeamStore.save(profiles: agentProfiles, teams: agentTeams)
        UserDefaults.standard.set(
            teamRoutingConsentAccountIDs.map(\.uuidString).sorted(),
            forKey: AgentTeamStore.consentKey
        )
    }

    /// Builds an in-memory manifest for one run. Provider credentials are
    /// included only in the WebSocket payload and are never written into the
    /// profile/team stores or transcript.
    func teamManifest(for text: String, teamID: UUID? = nil) -> [String: Any]? {
        let mention = TeamMentionResolver.selection(
            in: text,
            profiles: agentProfiles,
            teams: agentTeams
        )
        let team = teamID.flatMap { requested in
            agentTeams.first(where: { $0.id == requested })
        } ?? mention.team
            ?? selectedAgentTeam
            ?? mention.agent.flatMap { agent in
                agentTeams.first(where: { $0.memberIDs.contains(agent.id) })
            }
        guard let team else { return nil }
        let errors = AgentTeamValidation.errors(team: team, profiles: agentProfiles)
        guard errors.isEmpty else {
            showToast(errors[0])
            return nil
        }
        let routeErrors = AgentTeamValidation.routeErrors(
            team: team,
            profiles: agentProfiles,
            accounts: providerAccounts,
            accountModels: accountModels
        )
        guard routeErrors.isEmpty else {
            showToast(routeErrors[0])
            return nil
        }
        let members = team.memberIDs.compactMap { id in agentProfiles.first(where: { $0.id == id }) }
        for profile in members {
            guard let accountID = profile.route.accountID else { continue }
            guard teamRoutingConsentAccountIDs.contains(accountID) else {
                let label = providerAccounts.first(where: { $0.id == accountID })?.displayName
                    ?? "hosted account"
                showToast("Allow automatic team routing for \(label) in Agents & Teams")
                return nil
            }
        }
        let routes: [[String: Any]] = members.compactMap { profile in
            var route: [String: Any]
            switch profile.route {
            case .localOllama:
                route = [
                    "provider": "ollama",
                    "host": lastOllamaHost,
                ]
            case .providerAccount(let accountID):
                guard let account = providerAccounts.first(where: { $0.id == accountID }),
                      account.hasKey
                else { return nil }
                if account.kind == .chatGPT {
                    route = [
                        "provider": "chatgpt",
                        "account_id": account.id.uuidString,
                        "account_label": account.displayName,
                    ]
                } else {
                    route = [
                        "provider": "remote",
                        "base_url": account.resolvedBaseURL,
                        "api_key": CredentialStore.get(account: account.credentialAccount) ?? "",
                        "auth_style": account.kind.authStyle,
                        "lists_models": account.kind.listsModels,
                        "account_label": account.displayName,
                    ]
                }
            }
            var entry: [String: Any] = [
                "id": profile.id.uuidString,
                "name": profile.name,
                "model": profile.model,
                "role": profile.role.rawValue,
                "instructions": profile.instructions,
                "capabilities": profile.capabilityTags,
                "access_ceiling": profile.accessCeiling.rawValue,
                "timeout_seconds": profile.timeoutSeconds,
                "token_limit": profile.tokenLimit,
                "metering": route["provider"] as? String == "chatgpt"
                    ? AgentMetering.selfHosted.rawValue
                    : profile.metering.rawValue,
                "route": route,
            ]
            if let behavior = encodedJSONObject(profile.resolvedBehavior) {
                entry["behavior"] = behavior
            }
            if let rate = profile.inputCostPerMillion { entry["input_cost_per_million"] = rate }
            if let rate = profile.outputCostPerMillion { entry["output_cost_per_million"] = rate }
            if let policy = profile.mcpPolicy,
               let data = try? JSONEncoder().encode(policy),
               let value = try? JSONSerialization.jsonObject(with: data)
            {
                entry["mcp_policy"] = value
            }
            return entry
        }
        guard routes.count == members.count else {
            showToast("A team member's provider account is unavailable")
            return nil
        }
        var teamPayload: [String: Any] = [
            "id": team.id.uuidString,
            "name": team.name,
            "member_ids": team.memberIDs.map(\.uuidString),
            "use_managed_worktree": team.useManagedWorktree,
            "parallel_writers": team.resolvedParallelWriters,
            // One approval releases the complete plan. Individual jobs and
            // models do not introduce additional dispatch confirmations.
            "dispatch_approval_mode": DispatchApprovalMode.preview.rawValue,
            "routing_mode": team.resolvedRoutingMode.rawValue,
            "routing_weights": [
                "quality": team.resolvedRoutingWeights.quality,
                "reliability": team.resolvedRoutingWeights.reliability,
                "privacy": team.resolvedRoutingWeights.privacy,
                "latency": team.resolvedRoutingWeights.latency,
                "cost": team.resolvedRoutingWeights.cost,
            ],
            "evaluation_tags": team.evaluationTags ?? [],
            "maximum_estimated_cost": team.maximumEstimatedCost ?? 0,
            "budget": [
                "max_jobs": team.budget.maxJobs,
                "max_rounds": team.budget.maxRounds,
                "max_model_calls": team.budget.maxModelCalls,
                "max_concurrent_calls": team.budget.maxConcurrentCalls,
                "max_metered_tokens": team.budget.maxMeteredTokens,
                "call_budget_mode": team.budget.callBudgetMode.rawValue,
            ],
        ]
        if let id = team.dispatcherID { teamPayload["dispatcher_id"] = id.uuidString }
        if let id = team.fallbackDispatcherID { teamPayload["fallback_dispatcher_id"] = id.uuidString }
        if let id = team.defaultWriterID { teamPayload["default_writer_id"] = id.uuidString }
        var manifest: [String: Any] = [
            "run_id": UUID().uuidString,
            "team": teamPayload,
            "profiles": routes,
        ]
        if let id = mention.agent?.id { manifest["forced_agent_id"] = id.uuidString }
        return manifest
    }

    func refreshOrchestrationRuns(
        select runID: String? = nil,
        terminal: Bool = false
    ) async {
        let sessionID = currentSessionID
        let requestKey = [sessionID, terminal ? "terminal:\(runID ?? "")" : "routine"]
            .joined(separator: "|")
        let request: (generation: Int, task: Task<OrchestrationRunsResponse, Error>)
        if let existing = orchestrationRunsTasks[requestKey] {
            request = existing
        } else {
            orchestrationRunsGeneration += 1
            let generation = orchestrationRunsGeneration
            isLoadingOrchestrationRuns = true
            let query = sessionID.isEmpty
                ? []
                : [URLQueryItem(name: "session_id", value: sessionID)]
            let task = Task { [backend] in
                try await backend.get(
                    "/api/orchestrations",
                    query: query,
                    as: OrchestrationRunsResponse.self
                )
            }
            request = (generation, task)
            orchestrationRunsTasks[requestKey] = request
        }
        do {
            let response = try await request.task.value
            if orchestrationRunsTasks[requestKey]?.generation == request.generation {
                orchestrationRunsTasks.removeValue(forKey: requestKey)
            }
            guard request.generation == orchestrationRunsGeneration,
                  currentSessionID == sessionID
            else { return }
            isLoadingOrchestrationRuns = false
            if orchestrationRuns != response.runs {
                orchestrationRuns = response.runs
            }
            let selectedInCurrentSession = selectedOrchestrationRun.flatMap { selected in
                selected.sessionID == nil || selected.sessionID == sessionID ? selected.id : nil
            }
            let selectedID = runID ?? orchestrationRunID
                ?? selectedInCurrentSession ?? response.runs.first?.id
            if let selectedID {
                await loadOrchestrationRun(selectedID, terminal: terminal)
            } else if selectedOrchestrationRun?.sessionID != sessionID {
                selectedOrchestrationRun = nil
                orchestrationEvents = []
                orchestrationEventIDs = []
            }
        } catch {
            if orchestrationRunsTasks[requestKey]?.generation == request.generation {
                orchestrationRunsTasks.removeValue(forKey: requestKey)
            }
            guard !Task.isCancelled, request.generation == orchestrationRunsGeneration else { return }
            isLoadingOrchestrationRuns = false
            showToast("Could not load team runs: \(error.localizedDescription)")
        }
    }

    func loadOrchestrationRun(_ runID: String, terminal: Bool = false) async {
        let sameRun = selectedOrchestrationRun?.id == runID
        let afterSequence = sameRun ? orchestrationEvents.map(\.sequence).max() ?? 0 : 0
        let transport = orchestrationBackend(for: runID)
        let transportKey = transport.currentBaseURL.absoluteString
        let loadKey = "\(transportKey)|\(runID)|\(afterSequence)|\(terminal ? "terminal" : "routine")"
        let generation: Int
        if requestedOrchestrationLoadKey == loadKey {
            generation = orchestrationSelectionGeneration
        } else {
            orchestrationSelectionGeneration += 1
            generation = orchestrationSelectionGeneration
            requestedOrchestrationLoadKey = loadKey
            requestedOrchestrationRunID = runID
        }
        let detailKey = "\(transportKey)|\(runID)|\(terminal ? "terminal" : "routine")"
        let eventsKey = "\(transportKey)|\(runID)|\(afterSequence)|\(terminal ? "terminal" : "routine")"
        let detailTask = orchestrationDetailTask(
            runID: runID, key: detailKey, transport: transport
        )
        let eventsTask = orchestrationEventsTask(
            runID: runID,
            afterSequence: afterSequence,
            key: eventsKey,
            transport: transport
        )
        do {
            let detail = try await detailTask.value
            let response = try await eventsTask.value
            if orchestrationDetailTasks[detailKey] != nil {
                orchestrationDetailTasks.removeValue(forKey: detailKey)
            }
            if orchestrationEventTasks[eventsKey] != nil {
                orchestrationEventTasks.removeValue(forKey: eventsKey)
            }
            guard generation == orchestrationSelectionGeneration,
                  requestedOrchestrationRunID == runID
            else { return }
            let base = sameRun ? orchestrationEvents : []
            let merged = Self.mergeOrchestrationEvents(base, with: response.events)
            if selectedOrchestrationRun != detail {
                selectedOrchestrationRun = detail
            }
            if orchestrationEvents != merged {
                orchestrationEvents = merged
            }
            orchestrationEventIDs = Set(merged.map(\.id))
            if orchestrationRunID == runID,
               orchestrationState == nil,
               let state = TeamRunState(rawValue: detail.state),
               orchestrationState != state
            {
                orchestrationState = state
            }
        } catch {
            orchestrationDetailTasks.removeValue(forKey: detailKey)
            orchestrationEventTasks.removeValue(forKey: eventsKey)
            guard !Task.isCancelled, generation == orchestrationSelectionGeneration else { return }
            showToast("Could not inspect that run: \(error.localizedDescription)")
        }
    }

    func backfillOrchestrationEvents(_ runID: String) async {
        let after = orchestrationEvents
            .filter { $0.text("run_id") == runID }
            .map(\.sequence)
            .max() ?? 0
        let transport = orchestrationBackend(for: runID)
        let key = "\(transport.currentBaseURL.absoluteString)|\(runID)|\(after)|routine"
        let task = orchestrationEventsTask(
            runID: runID, afterSequence: after, key: key, transport: transport
        )
        do {
            let response = try await task.value
            orchestrationEventTasks.removeValue(forKey: key)
            guard selectedOrchestrationRun?.id == runID || orchestrationRunID == runID else { return }
            let merged = Self.mergeOrchestrationEvents(orchestrationEvents, with: response.events)
            if merged != orchestrationEvents {
                orchestrationEvents = merged
                orchestrationEventIDs = Set(merged.map(\.id))
            }
        } catch {
            orchestrationEventTasks.removeValue(forKey: key)
            // The inspector can still reload the full run on demand. A failed
            // reconnect backfill must not disturb the active transcript.
        }
    }

    nonisolated static func mergeOrchestrationEvents(
        _ existing: [OrchestrationEvent],
        with incoming: [OrchestrationEvent]
    ) -> [OrchestrationEvent] {
        var byID: [String: OrchestrationEvent] = [:]
        for event in existing where !event.isTransientStream { byID[event.id] = event }
        for event in incoming where !event.isTransientStream { byID[event.id] = event }
        return byID.values.sorted {
            $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence
        }
    }

    nonisolated static func orchestrationPickerRuns(
        _ runs: [OrchestrationRun],
        selected: OrchestrationRun?
    ) -> [OrchestrationRun] {
        guard let selected,
              !runs.contains(where: { $0.id == selected.id })
        else { return runs }
        return [selected] + runs
    }

    private func orchestrationDetailTask(
        runID: String,
        key: String,
        transport: BackendService
    ) -> Task<OrchestrationRun, Error> {
        if let existing = orchestrationDetailTasks[key] { return existing }
        let task = Task {
            try await transport.get(
                "/api/orchestrations/\(runID)", as: OrchestrationRun.self
            )
        }
        orchestrationDetailTasks[key] = task
        return task
    }

    private func orchestrationEventsTask(
        runID: String,
        afterSequence: Int,
        key: String,
        transport: BackendService
    ) -> Task<OrchestrationEventsResponse, Error> {
        if let existing = orchestrationEventTasks[key] { return existing }
        let task = Task {
            try await transport.get(
                "/api/orchestrations/\(runID)/events",
                query: [URLQueryItem(name: "after_seq", value: String(afterSequence))],
                as: OrchestrationEventsResponse.self
            )
        }
        orchestrationEventTasks[key] = task
        return task
    }

    func exportOrchestration(_ runID: String, includeContent: Bool) async {
        do {
            let value: [String: JSONValue] = try await backend.get(
                "/api/orchestrations/\(runID)/export",
                query: [URLQueryItem(
                    name: "include_content", value: includeContent ? "true" : "false"
                )],
                as: [String: JSONValue].self
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(runID).locusrun"
            panel.allowedContentTypes = [UTType(filenameExtension: "locusrun") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            showToast(includeContent ? "Run exported with visible content" : "Redacted run exported")
        } catch {
            showToast("Could not export run: \(error.localizedDescription)")
        }
    }

    private func exportOrchestrationToOTLP(_ runID: String) async {
        guard settings.otlpExportEnabled,
              !settings.otlpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            let _: SimpleActionResponse = try await backend.post(
                "/api/orchestrations/\(runID)/otlp",
                body: [
                    "endpoint": settings.otlpEndpoint,
                    "authorization": CredentialStore.get(
                        account: CredentialStore.otlpAuthorizationKey
                    ) ?? "",
                    "include_content": settings.otlpIncludeContent,
                ],
                as: SimpleActionResponse.self
            )
        } catch {
            showToast("Telemetry export failed: \(error.localizedDescription)")
        }
    }

    func saveOTLPAuthorization(_ value: String) {
        showToast(
            CredentialStore.set(value, account: CredentialStore.otlpAuthorizationKey)
                ? "Telemetry authorization saved"
                : "Could not save telemetry authorization"
        )
    }

    func pauseOrchestration(_ runID: String) {
        orchestrationAction(path: "/api/orchestrations/\(runID)/pause", runID: runID)
    }

    func cancelOrchestration(_ runID: String) {
        let transport = orchestrationBackend(for: runID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await transport.post(
                    "/api/orchestrations/\(runID)/cancel",
                    body: [:],
                    timeout: 30,
                    as: SimpleActionResponse.self
                )
                if orchestrationRunID == runID {
                    pendingDispatchPlan = nil
                    orchestrationState = .cancelled
                    steeringState = "Stopping the team run…"
                    updateTaskConversation(
                        state: .cancelled,
                        event: ["run_id": runID]
                    )
                }
                showToast("Stopping the team run")
                await refreshOrchestrationRuns(select: runID)
            } catch {
                showToast("Could not stop the team run: \(error.localizedDescription)")
            }
        }
    }

    func discardOrchestration(_ runID: String) {
        orchestrationAction(path: "/api/orchestrations/\(runID)/discard", runID: nil)
    }

    func cleanupOrchestrationCheckout(_ run: OrchestrationRun) {
        guard let taskID = run.taskID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/tasks/\(taskID)", as: SimpleActionResponse.self
                )
                if activeTaskRecord?.id == taskID {
                    activeTaskRecord = nil
                    taskHasChanges = false
                }
                showToast("Managed checkout removed; workspace files were not changed")
                await refreshOrchestrationRuns(select: run.id)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func setOrchestrationPinned(_ run: OrchestrationRun, pinned: Bool) {
        Task {
            do {
                let updated: OrchestrationRun = try await backend.patch(
                    "/api/orchestrations/\(run.id)",
                    body: ["pinned": pinned],
                    as: OrchestrationRun.self
                )
                selectedOrchestrationRun = updated
                await refreshOrchestrationRuns(select: updated.id)
            } catch {
                showToast("Could not update run: \(error.localizedDescription)")
            }
        }
    }

    func resumeOrchestration(_ run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("That team run is not paused or interrupted")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team, models, or hosted consent before resuming")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let assessment: RunRecoveryAssessment = try await backend.post(
                    "/api/orchestrations/\(run.id)/recovery-assessment",
                    body: ["manifest": manifest],
                    as: RunRecoveryAssessment.self
                )
                guard assessment.canResume else {
                    showToast(assessment.repairChecklist.first ?? "This run cannot be resumed")
                    return
                }
                orchestrationAction(
                    path: "/api/orchestrations/\(run.id)/resume",
                    body: ["manifest": manifest],
                    runID: run.id
                )
            } catch {
                showToast("Could not assess recovery: \(error.localizedDescription)")
            }
        }
    }

    func retryOrchestrationJob(_ attempt: AgentJobAttempt, in run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("Pause the team run before retrying a job")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team before retrying this job")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/jobs/\(attempt.jobID)/retry",
            body: ["manifest": manifest],
            runID: run.id
        )
    }

    func reassignOrchestrationJob(
        _ attempt: AgentJobAttempt,
        in run: OrchestrationRun,
        to profile: AgentProfile
    ) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("Pause the team run before reassigning a job")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team before reassigning this job")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/jobs/\(attempt.jobID)/reassign",
            body: ["manifest": manifest, "agent_id": profile.id.uuidString],
            runID: run.id
        )
    }

    func reassignmentCandidates(
        for attempt: AgentJobAttempt,
        in run: OrchestrationRun
    ) -> [AgentProfile] {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let team = agentTeams.first(where: { $0.id == teamID })
        else { return [] }
        return team.memberIDs.compactMap { id in
            agentProfiles.first(where: { $0.id == id })
        }.filter { profile in
            !profile.accessCeiling.canWrite
                && profile.id.uuidString != attempt.agentID
                && (attempt.role != "reviewer" || profile.role == .reviewer)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isCodingAttempt(_ attempt: AgentJobAttempt, in run: OrchestrationRun) -> Bool {
        guard case .object(let plan) = run.checkpoint?.state["plan"],
              case .array(let jobs) = plan["jobs"]
        else { return false }
        return jobs.contains { value in
            guard case .object(let job) = value else { return false }
            return job["id"]?.string == attempt.jobID && job["kind"]?.string == "writer"
        }
    }

    func replayOrchestration(_ run: OrchestrationRun) {
        startOrchestrationCopy(run, action: "replay")
    }

    func duplicateOrchestration(_ run: OrchestrationRun) {
        startOrchestrationCopy(run, action: "duplicate")
    }

    private func startOrchestrationCopy(_ run: OrchestrationRun, action: String) {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team, models, or hosted consent before continuing")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: OrchestrationMutationResponse = try await backend.post(
                    "/api/orchestrations/\(run.id)/\(action)",
                    body: ["manifest": manifest],
                    timeout: 30,
                    as: OrchestrationMutationResponse.self
                )
                orchestrationRunID = response.runID
                await refreshOrchestrationRuns(select: response.runID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func decideDispatch(_ action: String, editedPlan: DispatchPlan? = nil) {
        guard let runID = orchestrationRunID else { return }
        if action == "cancel" {
            cancelOrchestration(runID)
            return
        }
        var payload: [String: Any] = ["type": "dispatch_decision", "run_id": runID, "action": action]
        if let editedPlan, let value = encodedJSONObject(editedPlan) { payload["plan"] = value }
        guard orchestrationBackend(for: runID).send(payload) else {
            showToast("The dispatch decision could not be delivered")
            return
        }
        pendingDispatchPlan = nil
        if action == "redispatch" {
            orchestrationState = .dispatching
            dispatcherValidationReason = nil
            if var activity = dispatcherActivity {
                activity.state = .running
                activity.output = "Creating a new dispatcher plan…"
                activity.startedAt = Date()
                dispatcherActivity = activity
            }
            updateTaskConversation(state: .dispatching, event: ["run_id": runID])
        }
    }

    func dispatchPlanErrors(_ plan: DispatchPlan) -> [String] {
        let runTeamID = selectedOrchestrationRun?.teamID.flatMap(UUID.init(uuidString:))
        guard let team = runTeamID.flatMap({ id in agentTeams.first(where: { $0.id == id }) })
            ?? selectedAgentTeam
        else { return ["The selected team is unavailable."] }
        let profiles = Dictionary(uniqueKeysWithValues: agentProfiles.map { ($0.id, $0) })
        let budget = plan.budget ?? team.budget
        var errors: [String] = []
        if plan.jobs.isEmpty || plan.jobs.count > budget.maxJobs {
            errors.append("The plan must contain 1…\(budget.maxJobs) jobs.")
        }
        let ids = plan.jobs.map(\.id)
        if ids.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || Set(ids).count != ids.count
        {
            errors.append("Every job needs a unique ID.")
        }
        let known = Set(ids)
        for job in plan.jobs {
            guard let agentID = UUID(uuidString: job.agentID),
                  team.memberIDs.contains(agentID), let profile = profiles[agentID]
            else {
                errors.append("Job \(job.id) uses an unavailable team member.")
                continue
            }
            if job.kind == "writer" && !profile.accessCeiling.canWrite {
                errors.append("Coding job \(job.id) requires a write-capable team member.")
            }
            if job.kind != "writer" && profile.accessCeiling.canWrite {
                errors.append("Write-capable team members may only own coding jobs.")
            }
            if job.kind == "reviewer" && profile.role != .reviewer {
                errors.append("Reviewer jobs require a Reviewer profile.")
            }
            if let role = job.requiredRole, !role.isEmpty, profile.role.rawValue != role {
                errors.append("Job \(job.id) requires the \(role) role.")
            }
            if !Set(job.capabilityTags ?? []).isSubset(of: Set(profile.capabilityTags)) {
                errors.append("Job \(job.id) requires capabilities its agent does not have.")
            }
            if job.dependencies.contains(job.id)
                || job.dependencies.contains(where: { !known.contains($0) })
            {
                errors.append("Job \(job.id) has an invalid dependency.")
            }
        }
        let writerJobs = plan.jobs.filter { $0.kind == "writer" }
        if writerJobs.isEmpty {
            errors.append("The plan must contain at least one coding job.")
        }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        let dependencies = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0.dependencies) })
        func visit(_ id: String) -> Bool {
            if visited.contains(id) { return false }
            if visiting.contains(id) { return true }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] where visit(dependency) { return true }
            visiting.remove(id)
            visited.insert(id)
            return false
        }
        if ids.contains(where: visit) { errors.append("The job graph contains a dependency cycle.") }
        let kindByID = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0.kind) })
        for job in plan.jobs {
            if job.kind == "specialist",
               job.dependencies.contains(where: { kindByID[$0] != "specialist" })
            {
                errors.append("Specialists may depend only on specialist jobs.")
            }
            if job.kind == "writer",
               job.dependencies.contains(where: {
                   guard let kind = kindByID[$0] else { return false }
                   return kind != "specialist" && kind != "writer"
               })
            {
                errors.append("Coding jobs may depend only on specialists or earlier coding jobs.")
            }
        }
        func transitivelyDepends(_ jobID: String, on targetID: String, seen: inout Set<String>) -> Bool {
            guard seen.insert(jobID).inserted else { return false }
            for dependency in dependencies[jobID] ?? [] {
                if dependency == targetID { return true }
                if transitivelyDepends(dependency, on: targetID, seen: &seen) { return true }
            }
            return false
        }
        if writerJobs.count > 1 {
            for leftIndex in 0..<(writerJobs.count - 1) {
                for rightIndex in (leftIndex + 1)..<writerJobs.count {
                    var leftSeen: Set<String> = []
                    var rightSeen: Set<String> = []
                    let ordered = transitivelyDepends(
                        writerJobs[leftIndex].id,
                        on: writerJobs[rightIndex].id,
                        seen: &leftSeen
                    ) || transitivelyDepends(
                        writerJobs[rightIndex].id,
                        on: writerJobs[leftIndex].id,
                        seen: &rightSeen
                    )
                    if !ordered {
                        errors.append("Every pair of coding jobs must be ordered by a dependency.")
                    }
                }
            }
        }
        let minimumModelCalls = plan.jobs.count + 2 + (budget.maxRounds > 1 ? 1 : 0)
        if budget.maxModelCalls < minimumModelCalls {
            errors.append("This plan needs at least \(minimumModelCalls) model calls for its jobs, synthesis, and possible lead revision.")
        }
        if budget.maxConcurrentCalls > budget.maxModelCalls {
            errors.append("Concurrent calls cannot exceed the model-call budget.")
        }
        for id in team.memberIDs {
            if let accountID = profiles[id]?.route.accountID,
               !teamRoutingConsentAccountIDs.contains(accountID)
            {
                errors.append("Hosted automatic-routing consent is missing.")
                break
            }
        }
        return Array(Set(errors)).sorted()
    }

    private func orchestrationAction(
        path: String,
        body: [String: Any] = [:],
        runID: String?
    ) {
        let transport = runID.map(orchestrationBackend(for:)) ?? backend
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await transport.post(
                    path, body: body, timeout: 30, as: SimpleActionResponse.self
                )
                await refreshOrchestrationRuns(select: runID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func refreshEvaluations() async {
        do {
            let response: EvaluationSuitesResponse = try await backend.get(
                "/api/evaluations",
                query: [URLQueryItem(name: "workspace", value: workspacePath)],
                as: EvaluationSuitesResponse.self
            )
            evaluationSuites = response.suites
        } catch {
            showToast("Could not load evaluations: \(error.localizedDescription)")
        }
    }

    func loadEvaluationReport(_ suite: EvaluationSuite) async -> EvaluationReport? {
        do {
            return try await backend.get(
                "/api/evaluations/\(suite.id)", as: EvaluationReport.self
            )
        } catch {
            showToast("Could not load evaluation results: \(error.localizedDescription)")
            return nil
        }
    }

    func createEvaluationSuite() {
        let suite = EvaluationSuite(
            name: "Workspace checks",
            workspaceRoot: workspacePath,
            cases: [EvaluationCase(name: "First case", prompt: "Describe the expected task here.")]
        )
        saveEvaluationSuite(suite)
    }

    func saveEvaluationSuite(_ suite: EvaluationSuite) {
        guard let body = encodedJSONObject(suite) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: EvaluationSuiteResponse = try await backend.post(
                    "/api/evaluations", body: body, as: EvaluationSuiteResponse.self
                )
                evaluationSuites.removeAll { $0.id == response.suite.id }
                evaluationSuites.insert(response.suite, at: 0)
                showToast("Saved evaluation suite")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func deleteEvaluationSuite(_ suite: EvaluationSuite) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/evaluations/\(suite.id)", as: SimpleActionResponse.self
                )
                evaluationSuites.removeAll { $0.id == suite.id }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func importEvaluationSuite() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var suite = try JSONDecoder().decode(EvaluationSuite.self, from: Data(contentsOf: url))
            suite.id = UUID().uuidString
            saveEvaluationSuite(suite)
        } catch {
            showToast("Could not import evaluation suite: \(error.localizedDescription)")
        }
    }

    func exportEvaluationSuite(_ suite: EvaluationSuite) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(suite)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(suite.name.replacingOccurrences(of: "/", with: "-")) evaluation.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            showToast("Evaluation suite exported")
        } catch {
            showToast("Could not export evaluation suite: \(error.localizedDescription)")
        }
    }

    func runEvaluationSuite(_ suite: EvaluationSuite) {
        let needsTeam = suite.cases.contains { $0.target.caseInsensitiveCompare("team") == .orderedSame }
        var body: [String: Any] = [:]
        var manifests: [String: Any] = [:]
        for evaluationCase in suite.cases where evaluationCase.target == "team" {
            let requestedID = UUID(uuidString: evaluationCase.teamID) ?? selectedAgentTeamID
            guard let requestedID,
                  let manifest = teamManifest(for: evaluationCase.prompt, teamID: requestedID)
            else {
                showToast("Select or repair every team used by this suite")
                return
            }
            manifests[requestedID.uuidString] = manifest
        }
        if !manifests.isEmpty { body["manifests"] = manifests }
        if let selectedAgentTeamID,
           let fallback = teamManifest(
               for: suite.cases.first?.prompt ?? "", teamID: selectedAgentTeamID
           )
        {
            body["manifest"] = fallback
        }
        if needsTeam && manifests.isEmpty {
            showToast("Select a configured team before running this suite")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: EvaluationRunResponse = try await backend.post(
                    "/api/evaluations/\(suite.id)/run",
                    body: body,
                    as: EvaluationRunResponse.self
                )
                activeEvaluationID = response.evaluationID
                evaluationStatus = "Queued"
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func refreshWorkspaceKnowledge(agentID: String = "primary") async {
        do {
            let memoryQuery = [
                URLQueryItem(name: "workspace", value: workspacePath),
                URLQueryItem(name: "agent_id", value: agentID),
            ]
            async let status: WorkspaceKnowledgeStatus = backend.get(
                "/api/knowledge/status",
                query: [URLQueryItem(name: "workspace", value: workspacePath)],
                as: WorkspaceKnowledgeStatus.self
            )
            async let memories: WorkspaceMemoriesResponse = backend.get(
                "/api/memory",
                query: memoryQuery + [URLQueryItem(name: "status", value: "approved")],
                as: WorkspaceMemoriesResponse.self
            )
            async let candidates: WorkspaceMemoriesResponse = backend.get(
                "/api/memory",
                query: memoryQuery + [URLQueryItem(name: "status", value: "candidate")],
                as: WorkspaceMemoriesResponse.self
            )
            async let vaultStatus: MemoryVaultStatus = backend.get(
                "/api/memory/status", query: memoryQuery, as: MemoryVaultStatus.self
            )
            knowledgeStatus = try await status
            workspaceMemories = try await memories.memories
            memoryCandidates = try await candidates.memories
            memoryVaultStatus = try await vaultStatus
        } catch {
            showToast("Could not load workspace knowledge: \(error.localizedDescription)")
        }
    }

    func refreshBackgroundServices() {
        backgroundServicesRefreshGeneration += 1
        let generation = backgroundServicesRefreshGeneration
        let transport = conversationBackend
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await transport.get(
                    "/api/services", as: BackgroundServicesResponse.self
                )
                guard generation == backgroundServicesRefreshGeneration else { return }
                backgroundServices = response.services
            } catch {
                guard generation == backgroundServicesRefreshGeneration else { return }
                backgroundServices = []
            }
        }
    }

    func stopBackgroundService(_ service: BackgroundServiceRecord) {
        guard let encoded = service.name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return }
        // Stop is authoritative in the interface. Invalidate older in-flight
        // list requests so a stale response cannot make the service reappear.
        backgroundServicesRefreshGeneration += 1
        backgroundServices.removeAll { $0.name == service.name }
        let transport = conversationBackend
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await transport.delete(
                    "/api/services/\(encoded)", as: BackgroundServiceStopResponse.self
                )
                showToast(service.running ? "Stopped \(service.name)" : "Dismissed \(service.name)")
                refreshBackgroundServices()
            } catch {
                showToast("Could not stop \(service.name): \(error.localizedDescription)")
                refreshBackgroundServices()
            }
        }
    }

    func configureWorkspaceKnowledge(
        enabled: Bool,
        embeddingModel: String,
        exclusions: [String] = []
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                knowledgeStatus = try await backend.post(
                    "/api/knowledge/settings",
                    body: [
                        "workspace": workspacePath,
                        "enabled": enabled,
                        "embedding_model": embeddingModel,
                        "ollama_host": lastOllamaHost,
                        "exclusions": exclusions,
                    ],
                    as: WorkspaceKnowledgeStatus.self
                )
                showToast("Knowledge settings saved")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func rebuildWorkspaceKnowledge() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                knowledgeStatus = try await backend.post(
                    "/api/knowledge/reindex",
                    body: ["workspace": workspacePath],
                    timeout: 600,
                    as: WorkspaceKnowledgeStatus.self
                )
                await refreshWorkspaceKnowledge()
                showToast("Workspace knowledge rebuilt")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func rememberWorkspaceFact(
        title: String,
        content: String,
        tags: [String],
        scope: AgentMemoryScope = .workspace,
        kind: MemoryKind = .fact,
        confidence: Double = 1,
        validUntil: Double? = nil,
        agentID: String = "primary"
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var body: [String: Any] = [
                    "workspace": workspacePath,
                    "agent_id": agentID,
                    "scope": scope.rawValue,
                    "status": "approved",
                    "title": title,
                    "content": content,
                    "tags": tags,
                    "kind": kind.rawValue,
                    "confidence": confidence,
                    "source_session_id": currentSessionID,
                    "source_run_id": orchestrationRunID ?? "",
                ]
                if let validUntil { body["valid_until"] = validUntil }
                let response: WorkspaceMemoryResponse = try await backend.post(
                    "/api/memory",
                    body: body,
                    as: WorkspaceMemoryResponse.self
                )
                workspaceMemories.removeAll { $0.id == response.memory.id }
                workspaceMemories.insert(response.memory, at: 0)
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast("Remembered in \(scope.title.lowercased()) memory")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func deleteWorkspaceMemory(
        _ memory: WorkspaceMemory,
        agentID: String = "primary"
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/memory/\(memory.id)",
                    as: SimpleActionResponse.self
                )
                workspaceMemories.removeAll { $0.id == memory.id }
                memoryCandidates.removeAll { $0.id == memory.id }
                await refreshWorkspaceKnowledge(agentID: agentID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func updateWorkspaceMemory(_ memory: WorkspaceMemory, agentID: String = "primary") {
        guard let body = encodedJSONObject(memory) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var updateBody = [
                    "workspace": workspacePath,
                    "agent_id": agentID,
                ].merging(body) { _, new in new }
                // An omitted optional field means "leave unchanged" to the
                // vault. Send explicit null when the editor removes expiry.
                updateBody["valid_until"] = memory.validUntil ?? NSNull()
                let response: WorkspaceMemoryResponse = try await backend.put(
                    "/api/memory/\(memory.id)",
                    body: updateBody,
                    as: WorkspaceMemoryResponse.self
                )
                if let index = workspaceMemories.firstIndex(where: { $0.id == memory.id }) {
                    workspaceMemories[index] = response.memory
                }
                if let index = memoryCandidates.firstIndex(where: { $0.id == memory.id }) {
                    memoryCandidates[index] = response.memory
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func approveMemoryCandidate(
        _ memory: WorkspaceMemory,
        agentID: String = "primary",
        replacingConflicts: Bool = false
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: WorkspaceMemoryResponse = try await backend.post(
                    "/api/memory/\(memory.id)/approve",
                    body: [
                        "workspace": workspacePath,
                        "agent_id": agentID,
                        "resolution": replacingConflicts ? "replace" : "keep_both",
                    ],
                    as: WorkspaceMemoryResponse.self
                )
                memoryCandidates.removeAll { $0.id == memory.id }
                workspaceMemories.removeAll { $0.id == memory.id }
                workspaceMemories.insert(response.memory, at: 0)
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast("Memory approved")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func reviewMemoryHealth(agentID: String = "primary") {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: MemoryMaintenanceResponse = try await backend.post(
                    "/api/memory/maintenance/run",
                    body: ["workspace": workspacePath, "agent_id": agentID],
                    as: MemoryMaintenanceResponse.self
                )
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast(
                    "Memory review: \(response.expiredMarkedStale) expired, "
                        + "\(response.conflictCount) conflicts"
                )
            } catch {
                showToast("Could not review memory: \(error.localizedDescription)")
            }
        }
    }

    func exportMemory(agentID: String = "primary") {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let document: MemoryExportDocument = try await backend.get(
                    "/api/memory/export",
                    query: [
                        URLQueryItem(name: "workspace", value: workspacePath),
                        URLQueryItem(name: "agent_id", value: agentID),
                    ],
                    as: MemoryExportDocument.self
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Locus Memory.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                showToast("Memory exported — the chosen JSON file is readable text")
            } catch {
                showToast("Could not export memory: \(error.localizedDescription)")
            }
        }
    }

    func importMemory(agentID: String = "primary") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(MemoryExportDocument.self, from: data)
                guard let value = encodedJSONObject(document) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let response: MemoryImportResponse = try await backend.post(
                    "/api/memory/import",
                    body: [
                        "workspace": workspacePath,
                        "agent_id": agentID,
                        "document": value,
                    ],
                    as: MemoryImportResponse.self
                )
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast("Imported \(response.imported) memories")
            } catch {
                showToast("Could not import memory: \(error.localizedDescription)")
            }
        }
    }

    func openWorkspaceMemorySource(_ memory: WorkspaceMemory) {
        if let runID = memory.sourceRunID, !runID.isEmpty {
            selectInspectorTab(.agents)
            inspectorCollapsed = false
            Task { await loadOrchestrationRun(runID) }
            return
        }
        if let sessionID = memory.sourceSessionID,
           let session = sessions.first(where: { $0.id == sessionID })
        {
            resume(session)
        } else {
            showToast("The source chat is no longer available")
        }
    }

    func deleteAllWorkspaceKnowledge(agentID: String = "primary") {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/knowledge",
                    query: [URLQueryItem(name: "workspace", value: workspacePath)],
                    as: SimpleActionResponse.self
                )
                knowledgeStatus = nil
                workspaceMemories = []
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast("Deleted workspace knowledge")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func deleteAllMemory(agentID: String = "primary") {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/memory",
                    query: [
                        URLQueryItem(name: "workspace", value: workspacePath),
                        URLQueryItem(name: "agent_id", value: agentID),
                    ],
                    as: SimpleActionResponse.self
                )
                workspaceMemories = []
                memoryCandidates = []
                await refreshWorkspaceKnowledge(agentID: agentID)
                showToast("Deleted personal, workspace, and primary-agent memory")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func answerMCPInput(action: String, content: [String: Any] = [:]) {
        guard let request = mcpInputRequest else { return }
        let sent = backend.send([
            "type": "mcp_input_response",
            "request_id": request.id,
            "action": action,
            "content": content,
        ])
        if sent { mcpInputRequest = nil }
        else { showToast("The MCP input response could not be delivered") }
    }

    func applyActiveTaskToWorkspace() {
        guard let task = activeTaskRecord else { return }
        guard !isBusy, !hasPendingPermission else {
            showToast("Wait for the team run to finish before applying changes")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskApplyResponse = try await backend.post(
                    "/api/tasks/\(task.id)/apply",
                    body: [:],
                    timeout: 120,
                    as: TaskApplyResponse.self
                )
                activeTaskRecord = response.task
                taskHasChanges = false
                taskPatchBytes = 0
                refreshGitStatus()
                showToast(response.applied ? "Applied task changes to the workspace" : "No new task changes to apply")
            } catch {
                showToast("Workspace left untouched: \(error.localizedDescription)")
            }
        }
    }

    func copyActiveTaskPatch() {
        guard let task = activeTaskRecord else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskDetailResponse = try await backend.get(
                    "/api/tasks/\(task.id)",
                    as: TaskDetailResponse.self
                )
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(response.patch, forType: .string)
                showToast("Copied task patch")
            } catch {
                showToast("Could not copy the task patch: \(error.localizedDescription)")
            }
        }
    }

    func openActiveTaskCheckout() {
        guard let path = activeTaskRecord?.executionPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func revealActiveTaskCheckout() {
        guard let path = activeTaskRecord?.executionPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    /// Adds or updates an account. The key is written here rather than in the
    /// editor so an abandoned sheet leaves nothing behind; `apiKey` nil means
    /// "keep the saved one".
    func saveProviderAccount(_ account: ProviderAccount, apiKey: String?) {
        if account.kind == .chatGPT {
            if providerAccounts.contains(where: { $0.kind == .chatGPT && $0.id != account.id }) {
                showToast("Only one ChatGPT plan account can be added")
                return
            }
        } else {
            let effectiveKey = apiKey ?? CredentialStore.get(account: account.credentialAccount) ?? ""
            if let error = RemoteEndpointTester.securityError(
                baseURL: account.resolvedBaseURL,
                apiKey: effectiveKey
            ) {
                showToast(error)
                return
            }
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
        if let apiKey, updated.kind.requiresAPIKey {
            CredentialStore.set(apiKey, account: updated.credentialAccount)
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

    func refreshChatGPTAccount(forceTokenRefresh: Bool = false) async {
        let query = forceTokenRefresh
            ? [URLQueryItem(name: "refresh", value: "true")]
            : []
        do {
            let state = try await backend.get(
                "/api/chatgpt/account",
                query: query,
                as: ChatGPTAccountResponse.self
            )
            chatGPTAccount = state
            let status: ProviderAccountStatus = switch state.status {
            case "signed_in": .signedIn(email: state.email, plan: state.planType)
            case "runtime_unavailable":
                .runtimeUnavailable(state.message ?? "The ChatGPT runtime is unavailable")
            case "signing_in": .signingIn
            default: .signedOut
            }
            for account in providerAccounts where account.kind == .chatGPT {
                accountStatus[account.id] = status
            }
            if state.status == "signed_in" {
                chatGPTLoginID = nil
                await refreshChatGPTUsage()
            }
        } catch {
            let status = ProviderAccountStatus.runtimeUnavailable(error.localizedDescription)
            for account in providerAccounts where account.kind == .chatGPT {
                accountStatus[account.id] = status
            }
        }
    }

    func startChatGPTLogin() async {
        do {
            let response = try await backend.post(
                "/api/chatgpt/login/start",
                body: [:],
                as: ChatGPTLoginResponse.self
            )
            chatGPTLoginID = response.loginID
            for account in providerAccounts where account.kind == .chatGPT {
                accountStatus[account.id] = .signingIn
            }
            guard let url = URL(string: response.authURL), NSWorkspace.shared.open(url) else {
                showToast("Could not open the ChatGPT sign-in page")
                return
            }
        } catch {
            showToast("Could not start ChatGPT sign-in: \(error.localizedDescription)")
            await refreshChatGPTAccount()
        }
    }

    func cancelChatGPTLogin() async {
        guard let loginID = chatGPTLoginID else { return }
        do {
            let state = try await backend.post(
                "/api/chatgpt/login/cancel",
                body: ["login_id": loginID],
                as: ChatGPTAccountResponse.self
            )
            chatGPTLoginID = nil
            chatGPTAccount = state
            await refreshChatGPTAccount()
        } catch {
            showToast("Could not cancel ChatGPT sign-in: \(error.localizedDescription)")
        }
    }

    func signOutChatGPT() async {
        do {
            let state = try await backend.post(
                "/api/chatgpt/logout",
                body: [:],
                as: ChatGPTAccountResponse.self
            )
            chatGPTAccount = state
            chatGPTLoginID = nil
            for account in providerAccounts where account.kind == .chatGPT {
                accountStatus[account.id] = .signedOut
            }
            if activeAccount?.kind == .chatGPT {
                settings.activeAccountID = nil
                await applyProvider(announce: false)
            }
        } catch {
            showToast("Could not sign out of ChatGPT: \(error.localizedDescription)")
        }
    }

    func refreshChatGPTUsage() async {
        guard providerAccounts.contains(where: { $0.kind == .chatGPT }) else {
            chatGPTUsage = nil
            return
        }
        do {
            let usage = try await backend.get(
                "/api/chatgpt/usage",
                as: ChatGPTUsageResponse.self
            )
            chatGPTUsage = usage
            if let window = usage.rateLimits.rateLimits?.primary,
               window.usedPercent >= 100
            {
                let reset = window.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
                for account in providerAccounts where account.kind == .chatGPT {
                    accountStatus[account.id] = .rateLimited(resetAt: reset)
                }
            }
        } catch {
            // Usage is supplementary; the account and working providers stay
            // available when this one read fails.
        }
    }

    /// Removes an account, its key, and — if it was the one in use — the
    /// routing that depended on it.
    func removeProviderAccount(_ account: ProviderAccount) {
        providerAccounts.removeAll { $0.id == account.id }
        CredentialStore.remove(account: account.credentialAccount)
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
        CredentialStore.remove(account: account.credentialAccount)
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
        guard (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil else {
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
        guard !hasPendingPermission || taskWorkers[currentSessionID] != nil else {
            showToast("Answer the permission request before clearing")
            return
        }
        guard !isBusy || taskWorkers[currentSessionID] != nil, !pendingSessionReset else { return }
        detachForegroundWorkerUIIfNeeded()
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
        guard (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil else {
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
        guard (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil,
              !pendingSessionReset else {
            showToast("Finish the active run before starting another chat")
            return
        }
        detachForegroundWorkerUIIfNeeded()
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
        let currentIsBackgroundCapable = taskWorkers[currentSessionID] != nil
        guard (!isBusy && !hasPendingPermission) || currentIsBackgroundCapable else {
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
        if let runtime = taskWorkers[session.id] {
            activateWorkerSession(session, runtime: runtime)
            return
        }
        if currentIsBackgroundCapable { detachForegroundWorkerUIIfNeeded() }
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
                refreshAnchoredTeamRunsIfNeeded()
                applyPendingSearchHitIfNeeded()
                sessionInfo = response.sessionInfo
                currentSessionID = response.sessionInfo.sessionID
                dispatcherActivity = nil
                dispatcherValidationReason = nil
                agentActivities = response.agentActivities
                orchestrationState = response.orchestrationState
                orchestrationRunID = response.orchestrationRunID
                activeWorkerID = response.workerID
                if let state = response.orchestrationState {
                    taskConversationStates[response.sessionInfo.sessionID] = TaskConversationState(
                        sessionID: response.sessionInfo.sessionID,
                        taskID: response.sessionInfo.task?.id,
                        teamID: session.team?.id,
                        workerID: response.workerID,
                        runID: response.orchestrationRunID,
                        state: state,
                        updatedAt: Date()
                    )
                    if let runID = response.orchestrationRunID {
                        lifecycleJournal?.record(
                            sessionID: response.sessionInfo.sessionID,
                            runID: runID,
                            state: state
                        )
                    }
                }
                touchWorkspaceProfile(response.sessionInfo.cwd)
                showToast("Session resumed")
            } catch {
                blocks.append(ChatBlock(kind: .error, text: error.localizedDescription))
            }
        }
    }

    private func detachForegroundWorkerUIIfNeeded() {
        guard taskWorkers[currentSessionID] != nil else { return }
        computerControl.cancelPendingActions()
        // No browser cancellation here, at any scope: the worker keeps running
        // in the background and its browser actions are served on its own
        // socket regardless of which conversation is in front — cancelling
        // would kill an action that is still going to be answered.
        flushPendingTokens()
        finalizeStreamingBlocks()
        streamingAssistantID = nil
        streamingReply.resetTurn()
        isBusy = false
        orchestrationState = nil
        dispatcherActivity = nil
        dispatcherValidationReason = nil
        agentActivities = []
        activeTaskRecord = nil
        taskHasChanges = false
        taskPatchBytes = 0
    }

    private func activateWorkerSession(_ session: SessionSummary, runtime: TaskWorkerRuntime) {
        flushPendingTokens()
        finalizeStreamingBlocks()
        streamingAssistantID = nil
        streamingReply.resetTurn()
        currentSessionID = runtime.sessionID
        sessionInfo = runtime.sessionInfo
        if let info = runtime.sessionInfo { computerControl.beginSession(info.sessionID) }
        if let info = runtime.sessionInfo { browser.beginSession(info.sessionID) }
        syncBrowserProfile()
        Task {
            do {
                let detail = try await backend.get(
                    "/api/sessions/\(runtime.sessionID)",
                    as: SessionDetailResponse.self
                )
                blocks = Self.blocks(from: detail.messages)
                refreshAnchoredTeamRunsIfNeeded()
                agentActivities = detail.agentActivities ?? []
                orchestrationState = detail.orchestrationState
                    ?? taskConversationStates[runtime.sessionID]?.state
                    ?? detail.task?.state
                orchestrationRunID = detail.orchestrationRunID
                activeWorkerID = detail.workerID
                activeTaskRecord = detail.task ?? runtime.sessionInfo?.task
                let activeStates: Set<TeamRunState> = [
                    .queued, .dispatching, .running, .waitingPermission,
                    .waitingComputer, .reviewing,
                ]
                isBusy = orchestrationState.map(activeStates.contains) ?? false
                if let pending = runtime.pendingForegroundEvent {
                    runtime.pendingForegroundEvent = nil
                    handle(pending)
                }
                if let task = activeTaskRecord,
                   let taskDetail = try? await backend.get(
                       "/api/tasks/\(task.id)",
                       as: TaskDetailResponse.self
                   )
                {
                    taskHasChanges = taskDetail.patchBytes > 0
                    taskPatchBytes = taskDetail.patchBytes
                }
                touchWorkspaceProfile(session.workspacePath ?? workspacePath)
                showToast(isBusy ? "Running task opened" : "Task opened")
            } catch {
                blocks.append(ChatBlock(kind: .error, text: error.localizedDescription))
                isBusy = false
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
                // The conversation is gone; its pages have nothing to belong
                // to. (An Undo restores the transcript, not live tabs.)
                browser.closeTabs(ownedBy: session.id)
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
        guard !chatNavigationDisabled else {
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
        guard !chatNavigationDisabled else {
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
        guard (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil else {
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
        panel.title = "Attach files to this message"
        panel.message = "Locus will send only the files you choose; attachments never grant folder access."
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

    /// Attach images that exist only on the pasteboard — or were captured by
    /// the browser's annotator — under the same caps as file attachments:
    /// 10 files, 15 MB each, 25 MB of image data in total. Returns whether
    /// anything was attached, so callers holding user work (the annotation
    /// sheet) can refuse to discard it on a rejection.
    @discardableResult
    func addPastedImages(
        _ images: [(data: Data, mimeType: String)],
        nameStem: String = "Pasted image"
    ) -> Bool {
        guard !images.isEmpty else { return false }
        let remainingSlots = max(10 - chatAttachments.count, 0)
        guard remainingSlots > 0 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            return false
        }
        var totalImageBytes = chatAttachments.reduce(0) { $0 + ($1.imageData?.count ?? 0) }
        var added: [ChatAttachment] = []
        var oversized = 0
        for image in images.prefix(remainingSlots) {
            guard image.data.count <= 15_000_000,
                  totalImageBytes + image.data.count <= 25_000_000
            else {
                oversized += 1
                continue
            }
            totalImageBytes += image.data.count
            added.append(ChatAttachment.pasted(
                imageData: image.data,
                mimeType: image.mimeType,
                nameStem: nameStem
            ))
        }
        chatAttachments.append(contentsOf: added)
        chatAttachmentNotice = oversized > 0
            ? "Skipped or limited: \(oversized) over the size limit."
            : chatAttachmentNotice
        if !added.isEmpty {
            showToast("Attached \(added.count) image\(added.count == 1 ? "" : "s")")
        } else if oversized > 0 {
            showToast("The pasted image is over the size limit")
        }
        return !added.isEmpty
    }

    /// True only when the selected local model is known to refuse images.
    /// Remote models report nothing about vision, and an unknown is not a
    /// warning — the runtime strip-and-retry covers an actual rejection.
    var activeModelRejectsImages: Bool {
        guard activeAccount == nil else { return false }
        return models.first { $0.name == selectedModel }?.visionCapable == false
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

    func openWorkspaceInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspacePath)])
    }

    func openBackendFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.backendRoot))
    }

    func applySettings(_ newSettings: AppSettings, proxyCredentialChanged: Bool = false) {
        var newSettings = newSettings
        // Permissions are live controls, not part of the editable settings
        // draft. Preserve a choice made while this sheet was open.
        newSettings.permissionModeRaw = settings.permissionModeRaw
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
        let terminalChanged = settings.terminalShell != newSettings.terminalShell
            || settings.terminalLoginShell != newSettings.terminalLoginShell
        let proxyChanged = proxyCredentialChanged
            || settings.proxyModeRaw != newSettings.proxyModeRaw
            || settings.proxyTypeRaw != newSettings.proxyTypeRaw
            || settings.proxyHost != newSettings.proxyHost
            || settings.proxyPort != newSettings.proxyPort
            || settings.proxyBypass != newSettings.proxyBypass
            || settings.proxyUsername != newSettings.proxyUsername
        settings = newSettings
        appearancePreview = nil
        persistSettings()
        settingsPresented = false
        browser.defaultViewport = newSettings.resolvedBrowserViewport.size

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
        } else {
            if providerChanged {
                Task { await applyProvider() }
            }
        }
        if iterationLimitChanged {
            Task { await applyIterationLimit() }
        }
        if terminalChanged {
            terminal.configure(
                workspacePath: workspacePath,
                shell: newSettings.terminalShell,
                loginShell: newSettings.terminalLoginShell
            )
            Task { await applyTerminalSettings() }
        }
        showToast("Settings saved")
    }

    /// Preview never mutates `settings`, so Cancel can restore the committed
    /// appearance without triggering persistence or backend side effects.
    func previewAppearance(_ rawValue: String) {
        appearancePreview = AppAppearance(rawValue: rawValue) ?? .system
    }

    func clearAppearancePreview() {
        appearancePreview = nil
    }

    private func migrateTerminalSettingsIfNeeded() async {
        guard !settings.terminalSettingsMigrated else { return }
        do {
            let state = try await backend.get("/api/config", as: ConfigStateResponse.self)
            var updated = settings
            updated.terminalShell = state.terminalShell ?? updated.terminalShell
            updated.terminalLoginShell = state.terminalLoginShell ?? updated.terminalLoginShell
            updated.terminalSettingsMigrated = true
            settings = updated
            persistSettings()
            terminal.configure(
                workspacePath: workspacePath,
                shell: updated.terminalShell,
                loginShell: updated.terminalLoginShell
            )
        } catch {
            // Retry on the next successful metadata refresh; no preference is
            // marked migrated until the version-1 source was actually read.
        }
    }

    private func applyTerminalSettings() async {
        do {
            _ = try await backend.post(
                "/api/config",
                body: [
                    "terminal_shell": settings.terminalShell,
                    "terminal_login_shell": settings.terminalLoginShell,
                ],
                as: ConfigStateResponse.self
            )
        } catch {
            showToast("Could not update the Terminal settings: \(error.localizedDescription)")
        }
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
        if account.kind == .chatGPT {
            return [
                "provider": "chatgpt",
                "account_id": account.id.uuidString,
                "account_label": account.displayName,
                "model": account.preferredModel,
            ]
        }
        return [
            "provider": "remote",
            "base_url": account.resolvedBaseURL,
            "model": account.preferredModel,
            "api_key": CredentialStore.get(account: account.credentialAccount) ?? "",
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
        if let account, account.kind != .chatGPT, account.resolvedBaseURL.isEmpty {
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
            if let worker = taskWorkers[currentSessionID] {
                _ = try? await worker.service.post(
                    "/api/provider",
                    body: providerRequestBody(verify: false),
                    as: ProviderStateResponse.self
                )
            }
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
                state.provider == "remote" || state.provider == "chatgpt"
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
        gitUpstream = response.upstream
        gitAhead = response.ahead ?? 0
        gitBehind = response.behind ?? 0
        gitDetached = response.detached
        gitHasCommits = response.hasCommits
        if response.isRepo, originCheckedForWorkspace != workspacePath {
            originCheckedForWorkspace = workspacePath
            refreshOriginKind()
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

    // MARK: - Branch, remote, and PR flow

    /// Local branches, newest activity first, for the branch menu.
    func loadLocalBranches() {
        guard isGitRepository else { return }
        let client = gitClient
        Task { [weak self] in
            let result = try? await client.run([
                "for-each-ref", "refs/heads",
                "--format=%(refname:short)", "--sort=-committerdate",
            ])
            guard let self, let result else { return }
            localBranches = result.stdout
                .split(separator: "\n")
                .prefix(100)
                .map(String.init)
        }
    }

    /// `git switch -c`: safe on a dirty tree (edits ride along) and on an
    /// unborn HEAD. `check-ref-format` stays the naming authority.
    func createBranch(_ name: String) {
        let branch = name.trimmingCharacters(in: .whitespaces)
        if let problem = GitBranchName.validationError(branch) {
            showToast(problem)
            return
        }
        guard isGitRepository, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                try await client.run(["check-ref-format", "--branch", branch])
                try await client.run(["switch", "-c", branch])
                self?.showToast("Created and switched to \(branch)")
            } catch {
                self?.showToast(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshGitStatus()
        }
    }

    /// Plain `git switch`, no auto-stash: git itself refuses a switch that
    /// would clobber local edits, and that refusal is surfaced verbatim —
    /// the simplest behavior that can never lose work.
    func switchBranch(_ name: String) {
        guard isGitRepository, !isPerformingGitAction, name != gitBranch else { return }
        performGitAction(["switch", name], success: "Switched to \(name)")
    }

    /// Push the current branch; publish it when no upstream exists yet.
    func pushCurrentBranch() {
        guard GitRemoteFeatures.isAvailable, isGitRepository,
              !gitDetached, gitHasCommits, !isSyncingRemote,
              let branch = gitBranch
        else { return }
        isSyncingRemote = true
        let client = gitClient
        let args = GitPushPlan.arguments(branch: branch, upstream: gitUpstream)
        Task { [weak self] in
            do {
                try await client.run(args, timeout: 120)
                self?.showToast(
                    self?.gitUpstream == nil ? "Published \(branch)" : "Pushed \(branch)"
                )
            } catch {
                var message = error.localizedDescription
                if message.contains("rejected") || message.contains("non-fast-forward") {
                    message += " — Fetch/pull first, or push from a terminal."
                }
                self?.showToast(message)
            }
            self?.isSyncingRemote = false
            self?.refreshGitStatus()
        }
    }

    func fetchRemote() {
        guard GitRemoteFeatures.isAvailable, isGitRepository, !isSyncingRemote else { return }
        isSyncingRemote = true
        let client = gitClient
        Task { [weak self] in
            do {
                try await client.run(["fetch"], timeout: 60)
                self?.showToast("Fetched from the remote")
            } catch {
                self?.showToast(error.localizedDescription)
            }
            self?.isSyncingRemote = false
            self?.refreshGitStatus()
        }
    }

    /// `--ff-only`: the only merge-free, conflict-free pull. Its refusal
    /// ("not possible to fast-forward") is honest and surfaced as-is.
    func pullFastForwardOnly() {
        guard GitRemoteFeatures.isAvailable, isGitRepository, !isSyncingRemote else { return }
        isSyncingRemote = true
        let client = gitClient
        Task { [weak self] in
            do {
                let result = try await client.run(["pull", "--ff-only"], timeout: 120)
                let summary = result.stdout.split(separator: "\n").last.map(String.init)
                self?.showToast(summary?.nilIfEmpty ?? "Pulled fast-forward")
            } catch {
                self?.showToast(error.localizedDescription)
            }
            self?.isSyncingRemote = false
            self?.refreshGitStatus()
        }
    }

    /// Opens GitHub's compare page for the current branch — the human owns
    /// the actual PR creation. Reads the remote at click time; non-GitHub
    /// remotes never show the button, so a miss here only means the remote
    /// changed since the last status.
    func openPullRequest() {
        guard let branch = gitBranch else { return }
        let client = gitClient
        Task { [weak self] in
            guard let remote = try? await client.run(["remote", "get-url", "origin"]),
                  let url = GitRemoteURL.githubCompareURL(
                      remote: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                      branch: branch
                  )
            else {
                self?.showToast("The origin remote is not a GitHub repository")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func refreshOriginKind() {
        guard isGitRepository else { return }
        let client = gitClient
        Task { [weak self] in
            let remote = (try? await client.run(["remote", "get-url", "origin"]))?
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self else { return }
            originIsGitHub = GitRemoteURL.githubCompareURL(
                remote: remote, branch: "x"
            ) != nil
        }
    }

    // MARK: - Per-hunk review

    func stageHunk(_ hunk: DiffHunk) {
        performHunkAction(hunk, scope: .unstaged, apply: ["apply", "--cached"])
    }

    func unstageHunk(_ hunk: DiffHunk) {
        guard gitHasCommits else { return }
        performHunkAction(hunk, scope: .staged, apply: ["apply", "--cached", "-R"])
    }

    func requestDiscardHunk(_ hunk: DiffHunk) {
        pendingHunkDiscard = hunk
    }

    func discardHunkConfirmed() {
        guard let hunk = pendingHunkDiscard else { return }
        pendingHunkDiscard = nil
        performHunkAction(hunk, scope: .unstaged, apply: ["apply", "-R"])
    }

    private enum HunkScope {
        case staged
        case unstaged
    }

    /// The shared mechanics: re-take the diff at click time, re-locate the
    /// hunk (exact header, then content identity), synthesize the minimal
    /// patch, and apply. A hunk that drifted is never applied — the diff
    /// refreshes and the user reviews again.
    private func performHunkAction(
        _ hunk: DiffHunk,
        scope: HunkScope,
        apply applyArgs: [String]
    ) {
        guard isGitRepository, !isPerformingGitAction,
              let path = selectedChangePath,
              let change = gitChanges.first(where: { $0.path == path })
        else { return }
        isPerformingGitAction = true
        let client = gitClient
        let diffArgs = scope == .staged
            ? ["diff", "-U3", "--cached", "--", path]
            : ["diff", "-U3", "--", path]
        Task { [weak self] in
            defer {
                self?.isPerformingGitAction = false
                self?.refreshGitStatus()
                self?.loadDiff(for: change)
            }
            do {
                let fresh = try await client.run(diffArgs)
                guard let parsed = ParsedFileDiff.parse(fresh.stdout),
                      let located = parsed.matching(hunk),
                      let patch = parsed.minimalPatch(for: located)
                else {
                    self?.showToast(
                        "That change moved since the diff was read — review the refreshed diff"
                    )
                    return
                }
                do {
                    try await client.run(applyArgs, stdin: Data(patch.utf8))
                } catch {
                    // The agent's own git may hold index.lock for a moment.
                    try await Task.sleep(nanoseconds: 300_000_000)
                    try await client.run(applyArgs, stdin: Data(patch.utf8))
                }
            } catch {
                self?.showToast(error.localizedDescription)
            }
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

    /// Loads the diff for one file into `selectedChangeDiff`, plus the parsed
    /// hunk model that powers per-hunk staging. A truncated diff renders but
    /// parses to nil — hunk controls must never synthesize from partial text.
    func loadDiff(for change: GitChange, staged: Bool? = nil) {
        if let staged {
            selectedChangeShowsStaged = staged
        } else if selectedChangePath != change.path {
            // A fresh selection starts on the side that has content; a mixed
            // file keeps the scope its picker chose.
            selectedChangeShowsStaged = change.staged && !change.unstaged
        }
        selectedChangePath = change.path
        selectedChangeDiff = nil
        selectedChangeParsedDiff = nil
        diffTask?.cancel()
        guard !isUITesting else {
            seedUITestDiffIfNeeded(for: change)
            return
        }
        let wantsStaged = change.staged && (!change.unstaged || selectedChangeShowsStaged)
        diffTask = Task { [weak self] in
            do {
                let response = try await self?.backend.get(
                    "/api/git/diff",
                    query: [
                        URLQueryItem(name: "path", value: change.path),
                        URLQueryItem(name: "staged", value: wantsStaged ? "true" : "false"),
                    ],
                    as: GitDiffResponse.self
                )
                guard !Task.isCancelled, let self, let response else { return }
                guard self.selectedChangePath == change.path else { return }
                self.selectedChangeDiff = Self.cappedDiff(response)
                if !response.truncated, !response.binary, let raw = response.raw {
                    self.selectedChangeParsedDiff = ParsedFileDiff.parse(raw)
                }
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
        selectedChangeParsedDiff = nil
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

    // Zoomed, the panel fills the window regardless of `inspectorWidth`.
    var inspectorShowsLabels: Bool { inspectorZoomed || inspectorWidth >= 500 }

    func selectInspectorTab(_ tab: InspectorTab, selecting runID: String? = nil) {
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
        if tab == .terminal {
            terminal.configure(
                workspacePath: workspacePath,
                shell: settings.terminalShell,
                loginShell: settings.terminalLoginShell
            )
            DispatchQueue.main.async { [weak terminal] in
                terminal?.ensureStarted()
                terminal?.focus()
            }
        }
        if tab == .runs {
            Task { @MainActor [weak self] in
                await self?.refreshOrchestrationRuns(select: runID)
            }
        }
        if tab == .agents { refreshAgentInstructions() }
        settings.inspectorLastTab = tab.rawValue
        if tab.isWorkspaceTab {
            settings.inspectorLastWorkspaceTab = tab.rawValue
        }
    }

    /// Ctrl-` mirrors the familiar integrated-terminal gesture: reveal the
    /// terminal if needed, otherwise return keyboard focus to its PTY.
    func openTerminal() {
        selectInspectorTab(.terminal)
    }

    func openTeamRun(_ runID: String) {
        selectInspectorTab(.runs, selecting: runID)
    }

    private func refreshAnchoredTeamRunsIfNeeded() {
        guard blocks.contains(where: { $0.teamRunID != nil }) else { return }
        Task { @MainActor [weak self] in
            await self?.refreshOrchestrationRuns()
        }
    }

    func toggleInspector() {
        guard !justChatEnabled else { return }
        // The general panel button owns the workspace inspector, never a
        // special-purpose Plan or Browser surface. From either of those it
        // returns to the last workspace tab; a second press there collapses it.
        if !inspectorCollapsed, inspectorTab.isWorkspaceTab {
            inspectorCollapsed = true
        } else {
            selectInspectorTab(settings.resolvedInspectorWorkspaceTab)
        }
    }

    func presentInspectorForSentRequest(isTeam: Bool, runID: String? = nil) {
        // Just Chat deliberately has no workspace inspector, so it should not
        // consume the first-run choice for a panel that cannot be shown.
        guard !justChatEnabled else { return }
        let prompt = AutomaticInspectorPrompt(tab: isTeam ? .runs : .plan, runID: runID)
        let presentation = isTeam
            ? settings.resolvedTeamRunsPresentation
            : settings.resolvedSoloPlanPresentation
        switch presentation {
        case .ask:
            automaticInspectorPrompt = prompt
        case .always:
            openAutomaticInspector(prompt)
        case .never:
            break
        }
    }

    func answerAutomaticInspectorPrompt(showEveryTime: Bool) {
        guard let prompt = automaticInspectorPrompt else { return }
        automaticInspectorPrompt = nil
        let choice = showEveryTime
            ? AutomaticInspectorPresentation.always.rawValue
            : AutomaticInspectorPresentation.never.rawValue
        if prompt.isTeamRun {
            settings.teamRunsPresentationRaw = choice
        } else {
            settings.soloPlanPresentationRaw = choice
        }
        if showEveryTime {
            openAutomaticInspector(prompt)
        }
    }

    var shouldAskMessageSendShortcutPreference: Bool {
        !settings.sendShortcutPreferenceConfigured
    }

    func chooseMessageSendShortcut(enterSends: Bool) {
        var updated = settings
        updated.enterSendsMessages = enterSends
        updated.sendShortcutPreferenceConfigured = true
        settings = updated
    }

    private func openAutomaticInspector(_ prompt: AutomaticInspectorPrompt) {
        selectInspectorTab(prompt.tab, selecting: prompt.tab == .runs ? prompt.runID : nil)
    }

    /// Rail icon behavior: a click on the open panel's own tab closes the
    /// panel; anything else selects the tab (which opens the panel if needed).
    func toggleInspectorTab(_ tab: InspectorTab) {
        guard !justChatEnabled else { return }
        if !inspectorCollapsed, inspectorTab == tab {
            inspectorCollapsed = true
        } else {
            selectInspectorTab(tab)
        }
    }

    /// Expand the panel over the window, or hand the space back. Zooming
    /// opens a collapsed panel first, and borrows the session sidebar's
    /// room — remembering to give it back — so the panel gets real width
    /// without the window growing.
    func setInspectorZoomed(_ zoomed: Bool) {
        guard zoomed != inspectorZoomed else { return }
        if zoomed {
            guard !justChatEnabled else { return }
            if inspectorCollapsed { inspectorCollapsed = false }
            inspectorZoomed = true
            if !sidebarCollapsed {
                restoreSidebarAfterZoom = true
                let savedPreference = settings.sidebarCollapsed
                sidebarCollapsed = true
                // The borrow is zoom-owned, not a preference: its didSet write
                // must not survive a quit-while-zoomed, or relaunch — which
                // never restores zoom — would come back with the sidebar
                // silently gone.
                settings.sidebarCollapsed = savedPreference
            }
        } else {
            inspectorZoomed = false
            let shouldRestore = restoreSidebarAfterZoom
            restoreSidebarAfterZoom = false
            // Only reopen what zoom itself closed — if the user reopened the
            // sidebar while zoomed, their choice stands.
            if shouldRestore, sidebarCollapsed { sidebarCollapsed = false }
        }
    }

    func toggleInspectorZoom() {
        setInspectorZoomed(!inspectorZoomed)
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

    /// Live width of the chat column during a zoomed-divider drag. Same
    /// commit-on-release contract as `setInspectorWidth`.
    func setZoomedChatWidth(_ width: CGFloat) {
        zoomedChatWidth = CGFloat(AppSettings.clampZoomedChatWidth(Double(width)))
    }

    func commitZoomedChatWidth() {
        settings.inspectorZoomedChatWidth = Double(zoomedChatWidth)
    }

    // MARK: - Permission mode

    var permissionMode: PermissionMode {
        settings.preferredPermissionMode
            ?? sessionInfo?.permissions.effectiveMode
            ?? .ask
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
        settings.permissionModeRaw = mode.rawValue
        let transports = [backend] + taskWorkers.values.map(\.service)
        var latest: PermissionStateResponse?
        var failures = 0
        for transport in transports {
            do {
                latest = try await transport.post(
                    "/api/permissions",
                    body: ["mode": mode.rawValue],
                    as: PermissionStateResponse.self
                )
            } catch {
                failures += 1
            }
        }
        if let latest {
            applyPermissionState(latest)
        }
        if failures == 0 {
            showToast("Permissions: \(mode.title)")
        } else {
            showToast("Permissions saved; \(failures) busy runtime\(failures == 1 ? " will" : "s will") use it after reconnecting")
        }
    }

    private func syncPreferredPermissionMode(to transport: BackendService) {
        guard let mode = settings.preferredPermissionMode else { return }
        Task { [weak self] in
            guard let self else { return }
            if let state = try? await transport.post(
                "/api/permissions",
                body: ["mode": mode.rawValue],
                as: PermissionStateResponse.self
            ), transport === self.conversationBackend {
                self.applyPermissionState(state)
            }
        }
    }

    /// Clears the tools allowed for this session and returns to asking.
    func resetPermissions() {
        settings.permissionModeRaw = PermissionMode.ask.rawValue
        Task {
            var latest: PermissionStateResponse?
            var failures = 0
            for transport in [backend] + taskWorkers.values.map(\.service) {
                do {
                    latest = try await transport.post(
                        "/api/permissions",
                        body: ["reset": true],
                        as: PermissionStateResponse.self
                    )
                } catch {
                    failures += 1
                }
            }
            if let latest { applyPermissionState(latest) }
            showToast(failures == 0 ? "Permissions reset" : "Permissions reset; a busy runtime will update after reconnecting")
        }
    }

    /// Run one browser action and answer on the socket that asked for it.
    ///
    /// Deliberately not routed through `pendingForegroundEvent` the way
    /// computer actions are. Parking the request until the user happens to open
    /// that conversation is right for control of the real mouse and keyboard;
    /// for a web view it just means a background agent blocks until its deadline
    /// with nobody watching. Answering on the originating transport is what
    /// makes that safe — `conversationBackend` resolves to whichever session is
    /// in front, which is not necessarily the one that asked.
    /// Takes a reply closure rather than a transport so the routing — which
    /// socket the answer goes back on — is something a test can observe.
    @discardableResult
    func runBrowserAction(
        _ event: [String: Any],
        reply: @escaping @MainActor ([String: Any]) -> Void
    ) -> Task<Void, Never>? {
        guard let requestID = event["request_id"] as? String,
              let tool = event["tool"] as? String,
              let arguments = event["arguments"] as? [String: Any]
        else { return nil }
        let sessionID = (event["session_id"] as? String) ?? currentSessionID
        return Task { @MainActor [weak self] in
            guard let self else { return }
            // A browser surface appears only because the person selected it or
            // because the foreground agent is actively using it. Background
            // team workers keep running without pulling the current chat away.
            if sessionID == self.currentSessionID {
                self.selectInspectorTab(.preview)
            }
            let result = await self.browser.perform(
                tool: tool,
                arguments: arguments,
                sessionID: sessionID,
                hostedProvider: self.activeAccount?.displayName,
                timeoutMilliseconds: event["timeout_ms"] as? Int ?? 60_000
            )
            reply([
                "type": "browser_action_result",
                "request_id": requestID,
                "result": result,
            ])
        }
    }

    private func runBrowserAction(_ event: [String: Any], on transport: BackendService) {
        runBrowserAction(event) { payload in
            _ = transport.send(payload)
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
        for runtime in taskWorkers.values where runtime.sessionID != currentSessionID {
            sendComputerControlCapability(to: runtime.service)
            sendBrowserCapability(to: runtime.service)
        }
        showToast(enabled ? "Computer Control enabled" : "Computer Control disabled")
    }

    private func sendComputerControlCapability() {
        sendComputerControlCapability(to: conversationBackend)
    }

    private func sendComputerControlCapability(to transport: BackendService) {
        _ = transport.send([
            "type": "set_computer_control",
            "enabled": settings.computerControlEnabled,
            "native_available": ComputerControlService.isAvailable,
        ])
    }

    func setBrowserEnabled(_ enabled: Bool) {
        settings.browserEnabled = enabled
        announceBrowserCapability()
        showToast(enabled ? "Browser enabled" : "Browser disabled")
        if !enabled { browser.cancelPendingActions() }
    }

    func setBrowserPersistProfile(_ persistent: Bool) {
        settings.browserPersistProfile = persistent
        syncBrowserProfile()
    }

    /// Tell every live backend, not just whichever one happens to be in front.
    ///
    /// The computer-control version resolves `conversationBackend`, so when a
    /// worker session is foreground and the *main* backend reconnects, the
    /// announcement lands on the worker's socket and the reconnected agent
    /// never learns the capability. Naming the transports avoids inheriting
    /// that.
    private func announceBrowserCapability() {
        sendBrowserCapability(to: backend)
        for runtime in taskWorkers.values {
            sendBrowserCapability(to: runtime.service)
        }
    }

    private func sendBrowserCapability(to transport: BackendService) {
        let delivered = transport.send([
            "type": "set_browser_control",
            "enabled": settings.browserEnabled,
        ])
        // The agent refuses capability changes mid-turn and Swift historically
        // dropped the answer, so a toggle during a long turn was lost until the
        // next reconnect. Retry once the turn is over instead.
        if !delivered || isBusy {
            pendingBrowserCapabilityTransports.append(transport)
        }
    }

    /// Re-announce anything the agent refused while it was busy.
    private func flushPendingBrowserCapability() {
        guard !pendingBrowserCapabilityTransports.isEmpty else { return }
        let transports = pendingBrowserCapabilityTransports
        pendingBrowserCapabilityTransports.removeAll()
        for transport in transports {
            _ = transport.send([
                "type": "set_browser_control",
                "enabled": settings.browserEnabled,
            ])
        }
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

    /// Fetch the usage rollup for the dashboard. A failure leaves the previous
    /// summary in place; the sheet's spinner covers the initial load.
    func refreshUsageSummary(since: Double) {
        Task { [weak self] in
            guard let self else { return }
            let query = since > 0
                ? [URLQueryItem(name: "since", value: String(since))]
                : []
            guard let summary = try? await backend.get(
                "/api/usage/summary",
                query: query,
                as: UsageSummary.self
            ) else { return }
            usageSummary = summary
        }
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
        case .searchConversations:
            if sidebarCollapsed { toggleSidebar() }
            sidebarSearchFocusToken = UUID()
        case .showUsage: usageDashboardPresented = true
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

    /// SwiftUI queues a sibling sheet while Settings is still visible. Record
    /// the destination and complete the handoff from the dismissal callback.
    func openModelLibraryFromSettings() {
        modelLibraryPendingSettingsDismissal = true
        settingsPresented = false
    }

    func completeSettingsDismissal() {
        guard modelLibraryPendingSettingsDismissal else { return }
        modelLibraryPendingSettingsDismissal = false
        modelLibraryPresented = true
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
        guard BackendProcess.loopbackPortIsListening(at: backend.currentBaseURL) else {
            return false
        }
        return (try? await backend.get("/api/health", as: HealthResponse.self)) != nil
    }

    private func ensureTeamWorker(for requestedSessionID: String) async -> TaskWorkerRuntime? {
        if let existing = taskWorkers[requestedSessionID] { return existing }
        let process = BackendProcess()
        var workerEnvironment = ProxyConfigurator.agentEnvironmentOverlay(
            settings: settings,
            ollamaHost: lastOllamaHost
        )
        workerEnvironment["LOCUS_MODEL_CALL_LIMIT"] = String(globalAgentConcurrency)
        var brokerComponents = URLComponents(
            url: backend.currentBaseURL,
            resolvingAgainstBaseURL: false
        )
        brokerComponents?.scheme = backend.currentBaseURL.scheme == "https" ? "wss" : "ws"
        brokerComponents?.path = "/ws/internal/codex"
        if let brokerURL = brokerComponents?.url?.absoluteString {
            workerEnvironment["LOCUS_CODEX_BROKER_URL"] = brokerURL
            workerEnvironment["LOCUS_CODEX_BROKER_TOKEN"] = BackendSecurity.launchToken
        }
        let launch = process.start(
            root: settings.backendRoot,
            port: 0,
            cwd: workspacePath,
            environmentOverlay: workerEnvironment,
            proxyCredential: ProxyConfigurator.childCredential(
                settings: settings,
                password: persistenceEnabled ? CredentialStore.proxyPassword() : nil
            )
        )
        guard case .running(let endpoint) = launch else {
            if case .failed(let message) = launch { showToast(message) }
            return nil
        }
        let runtime = TaskWorkerRuntime(
            requestedSessionID: requestedSessionID,
            process: process,
            endpoint: endpoint
        )
        taskWorkers[requestedSessionID] = runtime
        runtime.process.onUnexpectedExit = { [weak self, weak runtime] _, output in
            Task { @MainActor in
                guard let self, let runtime else { return }
                if let key = self.taskWorkers.first(where: { $0.value === runtime })?.key {
                    self.taskWorkers.removeValue(forKey: key)
                }
                // The worker process died; nothing will drive its tabs again.
                self.browser.closeTabs(ownedBy: runtime.sessionID)
                self.syncBrowserProtectedSessions()
                let previous = self.taskConversationStates[runtime.sessionID]
                let runID = previous?.runID
                var durableRun: OrchestrationRun?
                if let runID {
                    durableRun = try? await self.backend.post(
                        "/api/orchestrations/\(runID)/reconcile-worker-exit",
                        body: ["worker_id": previous?.workerID ?? ""],
                        timeout: 5,
                        as: OrchestrationRun.self
                    )
                    if let durableRun {
                        self.orchestrationRuns.removeAll { $0.id == durableRun.id }
                        self.orchestrationRuns.insert(durableRun, at: 0)
                        if self.selectedOrchestrationRun?.id == durableRun.id {
                            self.selectedOrchestrationRun = durableRun
                        }
                    }
                }
                let interruptedState = durableRun.flatMap {
                    TeamRunState(rawValue: $0.state)
                } ?? .interrupted
                let state = TaskConversationState(
                    sessionID: runtime.sessionID,
                    taskID: runtime.sessionInfo?.task?.id,
                    teamID: previous?.teamID,
                    workerID: previous?.workerID,
                    runID: runID,
                    state: interruptedState,
                    updatedAt: Date()
                )
                self.taskConversationStates[runtime.sessionID] = state
                if let runID {
                    self.lifecycleJournal?.record(
                        sessionID: runtime.sessionID,
                        runID: runID,
                        state: interruptedState
                    )
                }
                if self.currentSessionID == runtime.sessionID {
                    self.isBusy = false
                    self.orchestrationState = interruptedState
                    let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.blocks.append(ChatBlock(
                        kind: .error,
                        text: detail.isEmpty ? "The task worker stopped unexpectedly." : String(detail.suffix(1_000))
                    ))
                }
            }
        }
        runtime.service.onConnectionChange = { [weak self, weak runtime] connected in
            runtime?.isConnected = connected
            // A worker that reconnects has a fresh agent process behind it,
            // which knows nothing about the capability until it is told again.
            guard connected, let self, let runtime else { return }
            self.sendBrowserCapability(to: runtime.service)
            self.syncPreferredPermissionMode(to: runtime.service)
        }
        runtime.service.onEvent = { [weak self, weak runtime] event in
            guard let self, let runtime else { return }
            self.handleWorkerEvent(event, runtime: runtime)
        }

        var healthy = false
        for _ in 0..<60 {
            if BackendProcess.loopbackPortIsListening(at: endpoint),
               (try? await runtime.service.get("/api/health", as: HealthResponse.self)) != nil
            {
                healthy = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard healthy else {
            taskWorkers.removeValue(forKey: requestedSessionID)
            runtime.stop()
            showToast("The task worker did not become ready")
            return nil
        }
        runtime.service.connect()
        for _ in 0..<40 where !runtime.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard runtime.isConnected else {
            taskWorkers.removeValue(forKey: requestedSessionID)
            runtime.stop()
            showToast("The task worker could not connect")
            return nil
        }

        let detail = try? await backend.get(
            "/api/sessions/\(requestedSessionID)",
            as: SessionDetailResponse.self
        )
        if let detail, !detail.messages.isEmpty,
           let response = try? await runtime.service.post(
               "/api/sessions/\(requestedSessionID)/resume",
               body: [:],
               as: ResumeResponse.self
           )
        {
            runtime.sessionID = response.sessionInfo.sessionID
            runtime.sessionInfo = response.sessionInfo
        } else if let info = runtime.sessionInfo {
            // A brand-new chat has no message record to resume. Its dedicated
            // worker's blank session becomes the chat before the first send.
            runtime.sessionID = info.sessionID
        } else {
            taskWorkers.removeValue(forKey: requestedSessionID)
            runtime.stop()
            showToast("The task worker did not publish its session")
            return nil
        }
        runtime.isAttaching = false
        if runtime.sessionID != requestedSessionID {
            taskWorkers.removeValue(forKey: requestedSessionID)
            taskWorkers[runtime.sessionID] = runtime
            if currentSessionID == requestedSessionID {
                currentSessionID = runtime.sessionID
            }
        }
        if currentSessionID == runtime.sessionID, let info = runtime.sessionInfo {
            sessionInfo = info
            activeTaskRecord = info.task
        }
        sendComputerControlCapability(to: runtime.service)
        sendBrowserCapability(to: runtime.service)
        syncPreferredPermissionMode(to: runtime.service)
        syncBrowserProtectedSessions()
        return runtime
    }

    /// Mirror the live worker set into the browser so tab eviction never
    /// sacrifices a tab an active agent is standing on.
    private func syncBrowserProtectedSessions() {
        browser.setProtectedSessions(Set(taskWorkers.values.map(\.sessionID)))
    }

    /// Keep the browsing profile pointed at the open workspace.
    func syncBrowserProfile() {
        browser.configureProfile(
            workspacePath: workspacePath,
            persistent: settings.browserPersistProfile
        )
    }

    private func handleWorkerEvent(_ event: [String: Any], runtime: TaskWorkerRuntime) {
        if let rawType = event["type"] as? String, rawType == "session_info",
           let info = decode(SessionInfo.self, from: event)
        {
            runtime.sessionInfo = info
            if runtime.isAttaching { return }
        }
        guard currentSessionID == runtime.sessionID, !runtime.isAttaching else {
            recordBackgroundWorkerEvent(event, runtime: runtime)
            return
        }
        handle(event)
    }

    private func recordBackgroundWorkerEvent(
        _ event: [String: Any],
        runtime: TaskWorkerRuntime
    ) {
        guard let type = event["type"] as? String else { return }
        let previous = taskConversationStates[runtime.sessionID]
        var state = previous?.state ?? .running
        if type == "orchestration_started" { state = .dispatching }
        if type == "orchestration_state",
           let raw = event["state"] as? String,
           let updated = TeamRunState(rawValue: raw) { state = updated }
        if type == "orchestration_completed",
           let raw = event["state"] as? String,
           let updated = TeamRunState(rawValue: raw) { state = updated }
        if type == "permission_request" {
            state = .waitingPermission
            runtime.pendingForegroundEvent = event
        }
        if type == "computer_action_request" {
            state = .waitingComputer
            runtime.pendingForegroundEvent = event
        }
        if type == "browser_action_request" {
            // Served straight away on this worker's own socket. Parking it the
            // way a computer action is parked would leave the worker blocked
            // until somebody opened its conversation.
            state = .waitingComputer
            runBrowserAction(event, on: runtime.service)
        }
        var taskID = runtime.sessionInfo?.task?.id ?? previous?.taskID
        if let raw = event["task"] as? [String: Any],
           let record = decode(TaskRecord.self, from: raw)
        {
            taskID = record.id
            runtime.sessionInfo = runtime.sessionInfo?.replacingTask(record)
            state = record.state ?? state
        }
        let updated = TaskConversationState(
            sessionID: runtime.sessionID,
            taskID: taskID,
            teamID: (event["team_id"] as? String) ?? previous?.teamID,
            workerID: (event["worker_id"] as? String) ?? previous?.workerID,
            runID: (event["run_id"] as? String) ?? previous?.runID,
            state: state,
            updatedAt: Date()
        )
        taskConversationStates[runtime.sessionID] = updated
        if let runID = updated.runID {
            lifecycleJournal?.record(
                sessionID: runtime.sessionID,
                runID: runID,
                state: state
            )
        }
        if (type == "orchestration_started" || type == "turn_done"), persistenceEnabled {
            Task { await refreshMetadata() }
        }
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
            // Just Chat keeps its isolation contract; agentic modes treat the
            // same files as evidence the agent may relate to the workspace.
            let guidance = mode == .ask
                ? "The user explicitly attached the following files to this message. "
                    + "Analyze only the supplied content; do not inspect their paths or access "
                    + "any other workspace data:"
                : "The user explicitly attached the following files as direct evidence "
                    + "for this request:"
            sections.append("\(guidance)\n\(contents)")
        }
        let imageNames = chatAttachments.filter {
            $0.kind == .image && $0.isAvailable
        }.map(\.name)
        if !imageNames.isEmpty {
            let guidance = mode == .ask
                ? ". Analyze the attached image data without accessing their paths."
                : ". They are direct evidence for this request; analyze the attached image data."
            sections.append(
                "The user explicitly attached these images to this message: "
                + imageNames.joined(separator: ", ")
                + guidance
            )
        }

        if let restoredTranscriptContext {
            sections.append("Restored session context:\n\(restoredTranscriptContext)")
            self.restoredTranscriptContext = nil
        }

        sections.append("User request:\n\(text)")
        return sections.joined(separator: "\n\n")
    }

    private func updateTaskConversation(
        state: TeamRunState,
        event: [String: Any],
        taskID: String? = nil
    ) {
        guard !currentSessionID.isEmpty else { return }
        let previous = taskConversationStates[currentSessionID]
        let updated = TaskConversationState(
            sessionID: currentSessionID,
            taskID: taskID ?? activeTaskRecord?.id ?? previous?.taskID,
            teamID: (event["team_id"] as? String) ?? previous?.teamID,
            workerID: (event["worker_id"] as? String) ?? activeWorkerID ?? previous?.workerID,
            runID: (event["run_id"] as? String) ?? orchestrationRunID ?? previous?.runID,
            state: state,
            updatedAt: Date()
        )
        if previous?.taskID == updated.taskID,
           previous?.teamID == updated.teamID,
           previous?.workerID == updated.workerID,
           previous?.runID == updated.runID,
           previous?.state == updated.state
        {
            return
        }
        taskConversationStates[currentSessionID] = updated
        if let runID = updated.runID {
            lifecycleJournal?.record(sessionID: currentSessionID, runID: runID, state: state)
        }
    }

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type != "agent_job_stream",
           event["event_id"] != nil,
           let runEvent = decode(OrchestrationEvent.self, from: event),
           !orchestrationEventIDs.contains(runEvent.id),
           selectedOrchestrationRun?.id == (event["run_id"] as? String)
                || orchestrationRunID == (event["run_id"] as? String)
        {
            orchestrationEventIDs.insert(runEvent.id)
            orchestrationEvents.append(runEvent)
            orchestrationEvents.sort { $0.sequence < $1.sequence }
        }
        switch type {
        case "chatgpt_account_updated":
            Task {
                await refreshChatGPTAccount()
                await refreshAccountCatalogs(force: true)
            }

        case "chatgpt_usage_updated":
            Task { await refreshChatGPTUsage() }

        case "worker_identity":
            activeWorkerID = event["worker_id"] as? String

        case "session_info":
            if let info = decode(SessionInfo.self, from: event) {
                activeWorkerID = event["worker_id"] as? String ?? activeWorkerID
                computerControl.beginSession(info.sessionID)
                browser.beginSession(info.sessionID)
                syncBrowserProfile()
                sessionInfo = info
                currentSessionID = info.sessionID
                watchWorkspaceKnowledge(info.workspaceRoot ?? info.cwd)
                activeTaskRecord = info.task
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
            if orchestrationRunID != nil {
                orchestrationState = .waitingPermission
                updateTaskConversation(state: .waitingPermission, event: event)
            }

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
            if orchestrationRunID != nil {
                orchestrationState = .running
                updateTaskConversation(state: .running, event: event)
            }

        case "workspace_changed":
            // The agent touched the tree; the Changes panel is now stale.
            refreshGitStatus()
            scheduleWorkspaceKnowledgeReindex(workspacePath)

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

        case "mcp_input_required":
            mcpInputRequest = decode(MCPInputRequest.self, from: event)

        case "mcp_input_rejected":
            let message = event["message"] as? String
                ?? "Sensitive MCP input must use a verified browser flow."
            showToast(message)

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

        case "orchestration_started":
            orchestrationRunID = event["run_id"] as? String
            orchestrationState = .dispatching
            activeWorkerID = event["worker_id"] as? String ?? activeWorkerID
            dispatcherActivity = nil
            dispatcherValidationReason = nil
            agentActivities = []
            teamModelCalls = 0
            teamMeteredTokens = 0
            pendingDispatchPlan = nil
            if let runID = orchestrationRunID {
                selectedOrchestrationRun = nil
                orchestrationEvents = []
                orchestrationEventIDs = []
                Task { @MainActor [weak self] in
                    await self?.loadOrchestrationRun(runID)
                }
            }
            updateTaskConversation(state: .dispatching, event: event)
            if persistenceEnabled { Task { await refreshMetadata() } }

        case "dispatcher_started":
            dispatcherValidationReason = nil
            let runID = event["run_id"] as? String ?? orchestrationRunID ?? "current"
            dispatcherActivity = AgentActivity(
                id: "dispatcher-\(runID)",
                agentName: event["agent_name"] as? String ?? "Dispatcher",
                role: AgentRole.dispatcher.rawValue,
                provider: event["provider"] as? String ?? "",
                model: event["model"] as? String ?? "",
                goal: event["goal"] as? String ?? "Creating the team plan",
                state: .running,
                output: "",
                reasoningText: nil,
                tool: nil,
                evidence: [],
                startedAt: Date(),
                elapsedMilliseconds: 0,
                promptTokens: 0,
                completionTokens: 0
            )

        case "dispatcher_completed":
            let state = (event["state"] as? String) == TeamRunState.failed.rawValue
                ? TeamRunState.failed : .completed
            if var activity = dispatcherActivity {
                activity.state = state
                activity.output = event["message"] as? String ?? "Dispatch plan ready"
                activity.elapsedMilliseconds = event["elapsed_ms"] as? Int ?? 0
                activity.promptTokens = event["prompt_tokens"] as? Int ?? 0
                activity.completionTokens = event["completion_tokens"] as? Int ?? 0
                dispatcherActivity = activity
            }
            if let usage = event["usage"] as? [String: Any] {
                teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
                teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
            }

        case "dispatcher_plan_rejected":
            dispatcherValidationReason = event["reason"] as? String
            if var activity = dispatcherActivity {
                activity.state = .running
                activity.output = event["message"] as? String
                    ?? event["reason"] as? String
                    ?? "Correcting dispatcher plan…"
                dispatcherActivity = activity
            }

        case "orchestration_state":
            if let state = (event["state"] as? String).flatMap(TeamRunState.init(rawValue:)) {
                if orchestrationState != state { orchestrationState = state }
                updateTaskConversation(state: state, event: event)
            }

        case "dispatch_plan_ready":
            orchestrationState = .waitingDispatchApproval
            if let raw = event["plan"] as? [String: Any] {
                pendingDispatchPlan = decode(DispatchPlan.self, from: raw)
            }
            updateTaskConversation(state: .waitingDispatchApproval, event: event)

        case "orchestration_recovery_available":
            if let raw = event["run"] as? [String: Any],
               let run = decode(OrchestrationRun.self, from: raw)
            {
                orchestrationRuns.removeAll { $0.id == run.id }
                orchestrationRuns.insert(run, at: 0)
                showToast("A team run can be resumed")
            }

        case "orchestration_paused":
            orchestrationState = .paused
            if let runID = event["run_id"] as? String {
                Task { @MainActor [weak self] in
                    await self?.loadOrchestrationRun(runID)
                }
            }

        case "orchestration_pause_requested":
            showToast("Pausing at the next safe boundary")

        case "evaluation_started":
            activeEvaluationID = event["evaluation_id"] as? String
            evaluationStatus = "Starting evaluation"

        case "evaluation_case_started":
            let index = (event["case_index"] as? Int ?? 0) + 1
            let count = event["case_count"] as? Int
            evaluationStatus = count.map { "Running case \(index) of \($0)" }
                ?? "Running case \(index)"

        case "evaluation_case_completed":
            evaluationStatus = "Grading results"

        case "evaluation_completed":
            activeEvaluationID = nil
            evaluationStatus = (event["state"] as? String) == "interrupted"
                ? "Evaluation interrupted" : "Evaluation complete"
            Task { @MainActor [weak self] in await self?.refreshEvaluations() }

        case "agent_job_started":
            let jobID = event["job_id"] as? String ?? UUID().uuidString
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .running
                agentActivities[index].startedAt = Date()
                agentActivities[index].writerJobID = event["writer_job_id"] as? String
                agentActivities[index].writerPosition = event["writer_position"] as? Int
                agentActivities[index].writerTotal = event["writer_total"] as? Int
            } else {
                agentActivities.append(AgentActivity(
                    id: jobID,
                    agentName: event["agent_name"] as? String ?? "Agent",
                    role: event["role"] as? String ?? "generalist",
                    provider: event["provider"] as? String ?? "",
                    model: event["model"] as? String ?? "",
                    goal: event["goal"] as? String ?? "",
                    state: .running,
                    output: "",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date(),
                    elapsedMilliseconds: 0,
                    promptTokens: 0,
                    completionTokens: 0,
                    writerJobID: event["writer_job_id"] as? String,
                    writerPosition: event["writer_position"] as? Int,
                    writerTotal: event["writer_total"] as? Int
                ))
            }

        case "agent_job_continuing":
            let jobID = event["job_id"] as? String ?? ""
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .running
                agentActivities[index].output = event["message"] as? String
                    ?? "Continuing coding job…"
            }
            if let usage = event["usage"] as? [String: Any] {
                teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
                teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
            }

        case "agent_job_incomplete":
            let jobID = event["job_id"] as? String ?? ""
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .paused
                agentActivities[index].output = event["message"] as? String
                    ?? "This coding job stopped before it finished."
                if let result = event["result"] as? [String: Any] {
                    agentActivities[index].elapsedMilliseconds = result["elapsed_ms"] as? Int ?? 0
                    agentActivities[index].promptTokens = result["prompt_tokens"] as? Int ?? 0
                    agentActivities[index].completionTokens = result["completion_tokens"] as? Int ?? 0
                }
            }
            orchestrationState = .paused
            if let usage = event["usage"] as? [String: Any] {
                teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
                teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
            }

        case "agent_job_completed":
            guard let result = event["result"] as? [String: Any] else { return }
            let jobID = result["job_id"] as? String ?? ""
            let state = (event["state"] as? String) == "failed"
                ? TeamRunState.failed : .completed
            let index = agentActivities.firstIndex(where: { $0.id == jobID })
            let activity = AgentActivity(
                id: jobID.isEmpty ? UUID().uuidString : jobID,
                agentName: result["agent_name"] as? String ?? "Agent",
                role: result["role"] as? String ?? "generalist",
                provider: index.map { agentActivities[$0].provider } ?? "",
                model: index.map { agentActivities[$0].model } ?? "",
                goal: index.map { agentActivities[$0].goal } ?? "",
                state: state,
                output: result["output"] as? String ?? result["error"] as? String ?? "",
                reasoningText: result["reasoning_text"] as? String,
                tool: nil,
                evidence: result["evidence"] as? [String] ?? [],
                startedAt: index.flatMap { agentActivities[$0].startedAt },
                elapsedMilliseconds: result["elapsed_ms"] as? Int ?? 0,
                promptTokens: result["prompt_tokens"] as? Int ?? 0,
                completionTokens: result["completion_tokens"] as? Int ?? 0,
                writerJobID: event["writer_job_id"] as? String
                    ?? index.flatMap { agentActivities[$0].writerJobID },
                writerPosition: event["writer_position"] as? Int
                    ?? index.flatMap { agentActivities[$0].writerPosition },
                writerTotal: event["writer_total"] as? Int
                    ?? index.flatMap { agentActivities[$0].writerTotal }
            )
            if let index { agentActivities[index] = activity } else { agentActivities.append(activity) }
            if let usage = event["usage"] as? [String: Any] {
                teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
                teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
            }

        case "orchestration_completed":
            let completedState = (event["state"] as? String)
                .flatMap(TeamRunState.init(rawValue:)) ?? .completed
            if orchestrationState != completedState { orchestrationState = completedState }
            updateTaskConversation(state: completedState, event: event)
            if let usage = event["usage"] as? [String: Any] {
                teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
                teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
            }
            if let runID = event["run_id"] as? String {
                // Reconnects can replay this durable terminal event. Only the
                // first copy should start the final metadata + incremental
                // timeline fetch; the live event itself is already deduped.
                if terminalRefreshRunIDs.insert(runID).inserted {
                    Task { @MainActor [weak self] in
                        await self?.refreshOrchestrationRuns(select: runID, terminal: true)
                        await self?.exportOrchestrationToOTLP(runID)
                    }
                }
            }

        case "task_ready":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
                taskHasChanges = false
                taskPatchBytes = 0
                updateTaskConversation(
                    state: record.state ?? orchestrationState ?? .running,
                    event: event,
                    taskID: record.id
                )
            }

        case "task_state":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
                let state = record.state
                    ?? (event["state"] as? String).flatMap(TeamRunState.init(rawValue:))
                    ?? .completed
                updateTaskConversation(state: state, event: event, taskID: record.id)
            }

        case "task_changes":
            taskHasChanges = event["has_changes"] as? Bool == true
            taskPatchBytes = event["patch_bytes"] as? Int ?? 0

        case "task_applied":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
            }
            taskHasChanges = false
            taskPatchBytes = 0
            showToast("Applied task changes to the workspace")

        case "computer_action_request":
            guard let requestID = event["request_id"] as? String,
                  let tool = event["tool"] as? String,
                  let arguments = event["arguments"] as? [String: Any]
            else { return }
            if orchestrationRunID != nil {
                orchestrationState = .waitingComputer
                updateTaskConversation(state: .waitingComputer, event: event)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.computerControl.perform(
                    tool: tool,
                    arguments: arguments,
                    hostedProvider: self.activeAccount?.displayName,
                    timeoutMilliseconds: event["timeout_ms"] as? Int ?? 60_000
                )
                _ = self.conversationBackend.send([
                    "type": "computer_action_result",
                    "request_id": requestID,
                    "result": result,
                ])
                if self.orchestrationRunID != nil {
                    self.orchestrationState = .running
                    self.updateTaskConversation(state: .running, event: event)
                }
            }

        case "computer_control_status":
            if (event["enabled"] as? Bool) != true, settings.computerControlEnabled {
                showToast("Computer Control is unavailable from the native broker")
            }

        case "browser_action_request":
            runBrowserAction(event, on: conversationBackend)

        case "browser_control_status":
            if (event["enabled"] as? Bool) != true, settings.browserEnabled {
                showToast("The browser is unavailable from the native broker")
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

        case "background_services_changed":
            refreshBackgroundServices()

        case "turn_done":
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            flushPendingBrowserCapability()
            let reason = event["reason"] as? String ?? "complete"
            let dispatchedMode = turnDispatchedMode
                ?? (turnDispatchedInPlanMode ? .plan : nil)
            if reason == "complete", dispatchedMode == .build {
                reconcileFinishedPlanStep()
            }
            if turnDispatchedTeamRunID == nil {
                appendTurnCompletion(
                    reason: reason,
                    mode: dispatchedMode,
                    backendDurationMilliseconds: event["duration_ms"] as? Int,
                    modelCallLimit: event["model_call_limit"] as? Int
                )
            }
            isBusy = false
            syncPreferredPermissionMode(to: conversationBackend)
            pendingRetry = false
            steeringState = nil
            mcpInputRequest = nil
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
            turnDispatchedTeamRunID = nil
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
            turnDispatchedTeamRunID = nil
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
        browser.beginSession(info.sessionID)
        sessionInfo = info
        syncBrowserProfile()
        currentSessionID = info.sessionID
        activeTaskRecord = info.task
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
            orchestrationRunID = nil
            orchestrationState = nil
            activeWorkerID = nil
            dispatcherActivity = nil
            dispatcherValidationReason = nil
            agentActivities = []
            teamModelCalls = 0
            teamMeteredTokens = 0
            taskHasChanges = false
            taskPatchBytes = 0
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
        backendDurationMilliseconds: Int?,
        modelCallLimit: Int? = nil
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
            iterationLimit: outcome == .maxIterations
                ? sessionInfo?.maxIterations
                : outcome == .modelCallBudget ? modelCallLimit : nil
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
        turnDispatchedTeamRunID = nil
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
            let route = stableWorkspaceRoute(for: path)
            workspaceProfiles.append(
                WorkspaceProfile(
                    path: path,
                    lastOpened: Date(),
                    model: route.model,
                    accountID: route.accountID,
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
        let route = stableWorkspaceRoute(for: path)
        let profile = WorkspaceProfile(
            path: path,
            lastOpened: Date(),
            model: route.model,
            accountID: route.accountID,
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

    /// Team jobs temporarily replace AgentCore's provider and model. Persist
    /// the user's solo route instead of pairing the last team member's model
    /// with an unrelated account and contaminating that account's picker.
    private func stableWorkspaceRoute(for path: String) -> (model: String, accountID: String?) {
        if let account = activeAccount {
            return (account.preferredModel, account.id.uuidString)
        }
        guard teamModeEnabled || orchestrationRunID != nil else {
            return (selectedModel, nil)
        }
        if let existing = workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path && $0.accountID == nil
        }), !existing.model.isEmpty {
            return (existing.model, nil)
        }
        let installed = localModels.first(where: { $0.name == selectedModel })?.name
            ?? localModels.first?.name
            ?? ""
        return (installed, nil)
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
        // Most UI tests exercise unrelated controls and should not be covered
        // by the first-run choice. Preference behavior has focused model tests.
        settings.automaticInspectorPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        settings.soloPlanPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        settings.teamRunsPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        settings.sendShortcutPreferenceConfigured =
            ProcessInfo.processInfo.environment["LOCUS_UI_TEST_SEND_SHORTCUT_PROMPT"] != "1"
        // The suite's inspector tests assume the panel starts open; the
        // collapsed default is covered by a settings unit test instead.
        inspectorTab = .plan
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
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_LONG_MODEL"] == "1" {
            let account = ProviderAccount(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                kind: .custom,
                name: "Long vLLM route",
                baseURLOverride: "https://example.invalid/v1",
                preferredModel: "/repository/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-NEO-MTP-Q8_0.gguf"
            )
            providerAccounts = [account]
            accountModels[account.id] = [account.preferredModel]
            accountStatus[account.id] = .connected(models: 1)
        }
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
        gitUpstream = "origin/main"
        gitAhead = 2
        gitBehind = 1
        gitHasCommits = true
        localBranches = ["main", "ship-test"]
        // Remote features stay hidden in the seeded run unless a UI test asks
        // for them, so the suite also covers the sandboxed layout.
        originIsGitHub =
            ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_GITHUB_ORIGIN"] == "1"
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
                path: "docs/terminal.md",
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
            "docs/terminal.md",
        ].map { URL(fileURLWithPath: workspace).appending(path: $0) }
        agentInstructionsExists = true
        savedAgentInstructions = "# Workspace instructions\n\n- Keep changes focused.\n"
        agentInstructionsDraft = savedAgentInstructions
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
        seedUITestRunFixtureIfNeeded()
    }

    /// A deterministic two-hunk diff so the seeded Changes tab has assertable
    /// per-hunk controls without a live agent behind it.
    func seedUITestDiffIfNeeded(for change: GitChange) {
        let raw = """
        diff --git a/\(change.path) b/\(change.path)
        index 1111111..2222222 100644
        --- a/\(change.path)
        +++ b/\(change.path)
        @@ -1,3 +1,3 @@
         let first = 1
        -let second = 2
        +let second = 22
         let third = 3
        @@ -10,3 +10,3 @@
         let tenth = 10
        -let eleventh = 11
        +let eleventh = 111
         let twelfth = 12
        """
        selectedChangeDiff = raw
        selectedChangeParsedDiff = ParsedFileDiff.parse(raw)
    }

    private func seedUITestRunFixtureIfNeeded() {
        guard let fixture = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_RUN_FIXTURE"],
              ["completed", "recoverable", "dispatcher-repair", "dispatch-plan"].contains(fixture)
        else { return }
        let state: TeamRunState = switch fixture {
        case "completed": .completed
        case "recoverable": .interrupted
        case "dispatch-plan": .waitingDispatchApproval
        default: .dispatching
        }
        let lastSequence = ["dispatcher-repair", "dispatch-plan"].contains(fixture) ? 1 : 1_200
        let run = OrchestrationRun(
            id: "seed-run",
            sessionID: "seed-current",
            teamID: "seed-team",
            teamName: "Codex Team",
            workerID: "seed-worker",
            workspaceRoot: "/tmp",
            executionPath: "/tmp",
            taskID: nil,
            state: state.rawValue,
            request: "Build a Pokémon Center stock checker",
            createdAt: Date().addingTimeInterval(-300).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            completedAt: fixture == "completed" ? Date().timeIntervalSince1970 : nil,
            lastSequence: lastSequence,
            pinned: false,
            legacy: false,
            recoverable: fixture == "recoverable",
            recoveryReason: fixture == "recoverable" ? "Saved checkpoint available" : nil,
            checkpoint: nil,
            attempts: nil,
            plan: nil,
            usage: ["model_calls": .number(12)],
            jobCount: 4,
            completedJobCount: fixture == "completed" ? 4 : 2
        )
        if let requestIndex = blocks.firstIndex(where: { $0.kind == .user }) {
            blocks[requestIndex].text = run.request
            blocks[requestIndex].teamRunID = run.id
        }
        orchestrationRuns = [run]
        selectedOrchestrationRun = run
        orchestrationRunID = run.id
        orchestrationState = state
        let rawEvents: [[String: Any]]
        if ["dispatcher-repair", "dispatch-plan"].contains(fixture) {
            let dispatcherID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
            let writerID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
            let teamID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
            let uiWriterID = UUID(uuidString: "00000000-0000-0000-0000-000000000504")!
            agentProfiles = [
                AgentProfile(
                    id: dispatcherID,
                    name: "Qwen Dispatcher",
                    model: "qwen3:8b",
                    role: .dispatcher
                ),
                AgentProfile(
                    id: writerID,
                    name: "Kimi Backend",
                    model: "qwen3:8b",
                    role: .implementer,
                    accessCeiling: .workspaceWrite
                ),
                AgentProfile(
                    id: uiWriterID,
                    name: "Kimi UI",
                    model: "qwen3:8b",
                    role: .implementer,
                    accessCeiling: .computerControl
                ),
            ]
            agentTeams = [AgentTeam(
                id: teamID,
                name: "Codex Team",
                dispatcherID: dispatcherID,
                fallbackDispatcherID: nil,
                memberIDs: [dispatcherID, writerID, uiWriterID],
                defaultWriterID: writerID
            )]
            selectedAgentTeamID = teamID
            isBusy = true
            if fixture == "dispatcher-repair" {
                dispatcherActivity = AgentActivity(
                    id: "dispatcher-seed-run",
                    agentName: "Qwen Dispatcher",
                    role: AgentRole.dispatcher.rawValue,
                    provider: "vLLM",
                    model: "qwen3:8b",
                    goal: "Creating the team plan",
                    state: .running,
                    output: "Correcting dispatcher plan…",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date().addingTimeInterval(-5),
                    elapsedMilliseconds: 0,
                    promptTokens: 0,
                    completionTokens: 0
                )
                dispatcherValidationReason = "dispatcher plan has no jobs"
                rawEvents = [[
                    "event_id": "seed-event-1",
                    "run_id": run.id,
                    "seq": 1,
                    "type": "dispatcher_plan_rejected",
                    "stage": "initial",
                    "message": "Correcting dispatcher plan…",
                    "reason": "dispatcher plan has no jobs",
                    "will_retry": true,
                ]]
            } else {
                dispatcherActivity = AgentActivity(
                    id: "dispatcher-seed-run",
                    agentName: "Qwen Dispatcher",
                    role: AgentRole.dispatcher.rawValue,
                    provider: "vLLM",
                    model: "qwen3:8b",
                    goal: "Creating the team plan",
                    state: .completed,
                    output: "Dispatch plan ready",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date().addingTimeInterval(-5),
                    elapsedMilliseconds: 5_000,
                    promptTokens: 1_000,
                    completionTokens: 250
                )
                pendingDispatchPlan = DispatchPlan(
                    summary: "Inspect the checker, implement the fix, and review it.",
                    jobs: [
                        DispatchJob(
                            id: "inspect",
                            agentID: dispatcherID.uuidString,
                            goal: "Inspect the current implementation and constraints",
                            dependencies: [],
                            kind: "specialist"
                        ),
                        DispatchJob(
                            id: "backend",
                            agentID: writerID.uuidString,
                            goal: "Implement and verify the stock-checking backend",
                            dependencies: ["inspect"],
                            kind: "writer"
                        ),
                        DispatchJob(
                            id: "ui",
                            agentID: uiWriterID.uuidString,
                            goal: "Build the UI against the completed backend contract",
                            dependencies: ["backend"],
                            kind: "writer"
                        ),
                    ],
                    budget: OrchestrationBudget(),
                    maximumEstimatedCost: nil
                )
                rawEvents = [[
                    "event_id": "seed-event-1",
                    "run_id": run.id,
                    "seq": 1,
                    "type": "dispatch_plan_ready",
                    "state": "waiting_dispatch_approval",
                ]]
            }
        } else {
            rawEvents = (1...1_200).map { sequence in
                [
                    "event_id": "seed-event-\(sequence)",
                    "run_id": run.id,
                    "seq": sequence,
                    "type": sequence == 1_200 ? "orchestration_completed" : "agent_job_completed",
                    "summary": sequence == 1_200 ? "Team run completed" : "Durable result \(sequence)",
                    "detail": String(repeating: "Verified output. ", count: 12),
                ]
            }
        }
        orchestrationEvents = rawEvents.compactMap {
            decode(OrchestrationEvent.self, from: $0)
        }
        orchestrationEventIDs = Set(orchestrationEvents.map(\.id))
        inspectorTab = .runs
        inspectorCollapsed = false
        if fixture == "completed",
           ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_STALE_QUIT_STATE"] == "1"
        {
            taskConversationStates[currentSessionID] = TaskConversationState(
                sessionID: currentSessionID,
                taskID: "seed-task",
                teamID: "seed-team",
                workerID: "seed-worker",
                runID: run.id,
                state: .running,
                updatedAt: Date().addingTimeInterval(-1)
            )
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_UNCLEAN_RECOVERY"] == "1" {
            lifecycleRecoveryMessage = fixture == "completed"
                ? "Locus was force quit after the team run completed. Its results were restored."
                : "Locus closed unexpectedly. This team run can be resumed from its saved checkpoint."
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

    private func encodedJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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

    static func blocks(from messages: [HistoryMessage]) -> [ChatBlock] {
        messages.enumerated().compactMap { index, message in
            switch message.role {
            case "user":
                ChatBlock(
                    kind: .user,
                    text: displayUserText(message.content),
                    teamRunID: message.teamRunID,
                    historyIndex: index
                )
            case "assistant" where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(message.reasoning?.isEmpty ?? true):
                ChatBlock(
                    kind: .assistant,
                    text: message.content,
                    reasoningText: message.reasoning,
                    historyIndex: index
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
                    ),
                    historyIndex: index
                )
            default:
                nil
            }
        }
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
    case searchConversations
    case showUsage
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
        case .searchConversations: "Search all conversations"
        case .showUsage: "Show usage and costs"
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
        case .searchConversations: "text.magnifyingglass"
        case .showUsage: "dollarsign.circle"
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
        case .searchConversations: "⇧⌘F"
        case .chooseWorkspace, .newWorkspace, .browseModels, .refreshModels,
             .exportSession, .permissions, .showUsage, .openSettings: ""
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

private struct TaskDetailResponse: Codable {
    let task: TaskRecord
    let tree: String
    let patch: String
    let patchBytes: Int

    enum CodingKeys: String, CodingKey {
        case task, tree, patch
        case patchBytes = "patch_bytes"
    }
}

private struct TaskApplyResponse: Codable {
    let task: TaskRecord
    let applied: Bool
    let tree: String
    let paths: [String]
}

private struct SimpleActionResponse: Codable {
    let ok: Bool
}

private struct OrchestrationMutationResponse: Codable {
    let ok: Bool
    let runID: String

    enum CodingKeys: String, CodingKey {
        case ok
        case runID = "run_id"
    }
}

private struct OrchestrationRunsResponse: Codable {
    let runs: [OrchestrationRun]
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case runs
        case readOnly = "read_only"
    }
}

private struct OrchestrationEventsResponse: Codable {
    let runID: String
    let events: [OrchestrationEvent]
    let lastSequence: Int

    enum CodingKeys: String, CodingKey {
        case events
        case runID = "run_id"
        case lastSequence = "last_seq"
    }
}

private struct EvaluationSuitesResponse: Codable {
    let suites: [EvaluationSuite]
}

private struct EvaluationSuiteResponse: Codable {
    let ok: Bool
    let suite: EvaluationSuite
}

private struct EvaluationRunResponse: Codable {
    let ok: Bool
    let evaluationID: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case ok, state
        case evaluationID = "evaluation_id"
    }
}

private struct WorkspaceMemoriesResponse: Codable {
    let memories: [WorkspaceMemory]
}

private struct WorkspaceMemoryResponse: Codable {
    let ok: Bool
    let memory: WorkspaceMemory
}

private struct MemoryExportDocument: Codable {
    let format: String
    let version: Int
    let exportedAt: Double
    let memories: [WorkspaceMemory]

    enum CodingKeys: String, CodingKey {
        case format, version, memories
        case exportedAt = "exported_at"
    }
}

private struct MemoryImportResponse: Codable {
    let ok: Bool
    let imported: Int
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
