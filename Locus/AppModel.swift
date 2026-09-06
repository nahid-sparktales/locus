import AppKit
import Combine
import Foundation
import PDFKit
import QuartzCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    let workspaceLayout = WorkspaceLayoutModel()
    let composerState = ComposerStateModel()
    let runtimeStatus = RuntimeStatusModel()
    /// Compatibility publication for views not yet moved to RuntimeStatusModel.
    /// RuntimeStatusModel remains the only owner of the underlying values.
    @Published private var runtimeFacadeRevision: UInt = 0
    @Published var backendCapabilities: [String: Bool] = [:]
    var automationWorkflowsEnabled: Bool {
        backendCapabilities["automation_workflows_v1"] == true
    }
    enum ProviderConnectionTestFollowUp: Equatable {
        case notNeeded
        case saveRequired
        case reconnected
        case reconnectFailed
    }

    var agentRuntimePhase: RuntimePhase {
        get { runtimeStatus.agentPhase }
        set {
            guard newValue != runtimeStatus.agentPhase else { return }
            runtimeStatus.setAgentPhase(newValue)
            runtimeFacadeRevision &+= 1
        }
    }
    var modelRuntimePhase: RuntimePhase {
        get { runtimeStatus.modelPhase }
        set {
            guard newValue != runtimeStatus.modelPhase else { return }
            runtimeStatus.setModelPhase(newValue)
            runtimeFacadeRevision &+= 1
        }
    }
    var isAgentOnline: Bool { agentRuntimePhase.isOnline }
    var isModelOnline: Bool { modelRuntimePhase.isOnline }
    let providerAccountsModel: ProviderAccountsModel
    private var providerAccountsCapabilityObservation: AnyCancellable?
    let voiceControl = VoiceControlModel()

    #if !LOCUS_APP_STORE
    /// The ChatGPT-plan helpers ship as a downloadable component in the direct
    /// download. Owned here so the account editor and the settings row observe
    /// the same install rather than racing two of them.
    let codexComponent = CodexComponentInstaller()
    #endif

    #if !LOCUS_APP_STORE
    /// Installs the ChatGPT-plan component and then re-reads the account.
    ///
    /// The refresh is the point: the backend only reports `runtime_available`
    /// again once it re-stats the helper path, and without this the user is
    /// left looking at a sign-in button that is still disabled from the check
    /// made before the component existed.
    func installCodexComponent(for account: ProviderAccount) async {
        codexComponent.install()
        await codexComponent.waitForCompletion()
        if case .installed = codexComponent.state {
            await providerAccountsModel.refreshChatGPTAccount(for: account)
        }
    }
    #endif

    /// True when a ChatGPT-plan sign-in is blocked only because the helper
    /// component has not been downloaded yet — as opposed to the runtime being
    /// present but broken, which needs a different message.
    var chatGPTComponentMissing: Bool {
        #if LOCUS_APP_STORE
        false
        #else
        CodexComponent.bundledHelper == nil && !CodexComponent.isInstalled
        #endif
    }
    let agentTeamsModel: AgentTeamsModel
    @Published var orchestrationRunID: String?  // internal(for: AppModel+UITestFixtures)
    @Published var orchestrationState: TeamRunState?  // internal(for: AppModel+UITestFixtures)
    @Published var activeWorkerID: String?  // internal(for: AppModel extension files)
    @Published var taskConversationStates: [String: TaskConversationState] = [:]  // internal(for: AppModel+UITestFixtures)
    let teamRunLive = TeamRunLiveModel()
    @Published var activeTaskRecord: TaskRecord?  // internal(for: AppModel+UITestFixtures)
    var pendingProviderSwitch: (accountID: UUID?, model: String)?  // internal(for: AppModel extension files)
    let landingFlow = LandingFlowModel()
    let runs = OrchestrationRunsModel()
    @Published var runsNavigationRequest: RunsNavigationRequest?  // internal(for: AppModel+UITestFixtures)
    let evaluations = EvaluationsModel()
    let knowledge = WorkspaceKnowledgeModel()
    let activity = ActivityCenterModel()
    let schedule = ScheduleModel()
    let companionGateway = CompanionGateway()
    @Published private(set) var companionGatewayState = CompanionGatewayState.disabled
    @Published var companionPairingPayload: CompanionPairingPayload?  // internal(for: AppModel+MobileCompanion)
    @Published var companionPairingError: String?  // internal(for: AppModel+MobileCompanion)
    let backgroundServicesModel = BackgroundServicesModel()
    let extensionsModel: ExtensionsModel
    let sessionCatalog = SessionCatalogModel()
    let transcriptPresentation = TranscriptPresentationModel()
    /// Compatibility notification for an AppModel-owned identity transition,
    /// after the transcript's identity and rows have committed together. This
    /// is not a subscription to child publications: content and streaming
    /// changes remain isolated in TranscriptPresentationModel.
    @Published private var transcriptSessionTransitionRevision: UInt64 = 0
    enum TranscriptInputState: Equatable {
        case ready
        case loading
        case unavailable

        var explanation: String? {
            switch self {
            case .ready: nil
            case .loading: "Loading this conversation. Your draft is kept."
            case .unavailable: "Reopen this conversation before sending. Your draft is kept."
            }
        }
    }
    @Published private(set) var transcriptInputState = TranscriptInputState.ready
    var canAcceptTranscriptInput: Bool { transcriptInputState == .ready }
    var sessions: [SessionSummary] {
        get { sessionCatalog.snapshot.sessions }
        set { sessionCatalog.replaceSessions(newValue) }
    }
    var chatFolders: [ChatFolderRecord] {
        get { sessionCatalog.snapshot.chatFolders }
        set { sessionCatalog.replaceChatFolders(newValue) }
    }
    var currentSessionID: String {
        get { transcriptPresentation.snapshot.sessionID }
        set {
            guard currentSessionID != newValue else { return }
            invalidatePendingTranscriptTransition()
            if transcriptInputState == .loading { transcriptInputState = .unavailable }
            commitTranscriptIdentityTransition {
                transcriptPresentation.beginSession(newValue)
            }
        }
    }
    @Published var chatSplitRestoration = ChatSplitRestoration.empty  // internal(for: AppModel extension files)
    let primaryChatPaneState = ChatPaneState(id: .primary)
    let secondaryChatPaneState = ChatPaneState(id: .secondary)
    @Published var splitPaneBlocks: [String: [ChatBlock]] = [:]  // internal(for: AppModel extension files)
    @Published var splitPaneDrafts: [String: String] = [:]  // internal(for: AppModel extension files)
    var splitPaneAttachments: [String: [ChatAttachment]] = [:]  // internal(for: AppModel extension files)
    var splitPaneModes: [String: WorkMode] = [:]  // internal(for: AppModel extension files)
    var splitPaneTeams: [String: UUID?] = [:]  // internal(for: AppModel extension files)
    var splitPaneSoloRouting: [String: Bool] = [:]  // internal(for: AppModel extension files)
    var splitPaneSearchQueries: [String: String] = [:]  // internal(for: AppModel extension files)
    static let splitRestorationKey = "Locus.chatSplitRestoration"  // internal(for: AppModel extension files)
    var didRestoreChatSplit = false  // internal(for: AppModel extension files)
    @Published var sessionInfo: SessionInfo? {
        didSet {
            // Session changes must retarget the app-owned PTY even when its
            // inspector tab is hidden. Ignore a transient nil while the local
            // backend reconnects so the shell survives agent restarts.
            if let cwd = sessionInfo?.cwd, !cwd.isEmpty {
                sessionCatalog.setActiveWorkspacePath(cwd)
            } else if let initialWorkspacePath {
                sessionCatalog.setActiveWorkspacePath(initialWorkspacePath)
            }
            guard let cwd = sessionInfo?.cwd, !cwd.isEmpty else { return }
            terminal.configure(
                workspacePath: cwd,
                shell: settings.terminalShell,
                loginShell: settings.terminalLoginShell
            )
            ProxyRuntime.shared.noteRoutingContext(
                workspacePath: cwd,
                providerAccountID: settings.activeAccountID
            )
        }
    }
    var blocks: [ChatBlock] {
        get { transcriptPresentation.snapshot.blocks }
        set { transcriptPresentation.replaceBlocks(newValue) }
    }

    func updateTranscriptBlocks(_ update: (inout [ChatBlock]) -> Void) {
        transcriptPresentation.updateBlocks(update)
    }

    func installTranscriptSession(
        _ sessionID: String, blocks: [ChatBlock], forceNewGeneration: Bool = false
    ) {
        commitTranscriptIdentityTransition {
            transcriptPresentation.installSession(
                sessionID, blocks: blocks, forceNewGeneration: forceNewGeneration
            )
        }
    }

    func rekeyTranscriptSession(to sessionID: String) {
        guard currentSessionID != sessionID else { return }
        commitTranscriptIdentityTransition {
            transcriptPresentation.rekeySession(from: currentSessionID, to: sessionID)
        }
    }

    func beginTranscriptSessionLoad(_ sessionID: String) -> TranscriptSessionLoadToken {
        invalidatePendingTranscriptTransition()
        transcriptInputState = .loading
        return commitTranscriptIdentityTransition {
            transcriptPresentation.beginSessionLoad(sessionID)
        }
    }

    @discardableResult
    func completeTranscriptSessionLoad(
        _ token: TranscriptSessionLoadToken, sessionID: String, blocks: [ChatBlock]
    ) -> Bool {
        guard transcriptPresentation.ownsSessionLoad(token),
              transcriptPresentation.loadingSessionID != nil else { return false }
        return commitTranscriptIdentityTransition {
            transcriptPresentation.completeSessionLoad(token, sessionID: sessionID, blocks: blocks)
        }
    }

    /// Notify compatibility consumers only for an identity change that this
    /// synchronous orchestration operation actually committed. Observers read
    /// the already-coherent child snapshot; no identity or row copy is stored
    /// here, and rejected/no-op/content-only mutations publish nothing.
    private func commitTranscriptIdentityTransition<Result>(_ mutation: () -> Result) -> Result {
        let previousID = currentSessionID
        let result = mutation()
        if currentSessionID != previousID { transcriptSessionTransitionRevision &+= 1 }
        return result
    }

    /// Loading the rows alone is insufficient: the send path also snapshots
    /// the selected session's workspace and task. Publish readiness only once
    /// that same owned operation has finished applying its metadata.
    func finishTranscriptInputLoad(_ token: TranscriptSessionLoadToken) {
        guard transcriptPresentation.ownsSessionLoad(token) else { return }
        transcriptInputState = sessionInfo?.sessionID == currentSessionID ? .ready : .unavailable
    }

    func failTranscriptInputLoad(_ token: TranscriptSessionLoadToken) {
        guard transcriptPresentation.ownsSessionLoad(token) else { return }
        transcriptInputState = .unavailable
        transcriptPresentation.cancelSessionLoad(token)
    }

    func transcriptSessionMetadataDidBecomeReady() {
        transcriptInputState = .ready
    }

    @Published var todos: [TodoItem] = []
    var isBusy: Bool {
        get { runtimeStatus.isBusy }
        set {
            guard newValue != runtimeStatus.isBusy else { return }
            runtimeStatus.setBusy(newValue)
            runtimeFacadeRevision &+= 1
        }
    }
    private(set) var hasPendingPermission: Bool {
        get { runtimeStatus.hasPendingPermission }
        set {
            guard newValue != runtimeStatus.hasPendingPermission else { return }
            runtimeStatus.setPendingPermission(newValue)
            runtimeFacadeRevision &+= 1
        }
    }
    /// A short, truthful description of where an in-flight steering request
    /// is waiting. It is cleared when the direction joins the active turn.
    var steeringState: String? {  // internal(for: AppModel extension files)
        get { runtimeStatus.steeringState }
        set {
            guard newValue != runtimeStatus.steeringState else { return }
            runtimeStatus.setSteeringState(newValue)
            runtimeFacadeRevision &+= 1
        }
    }
    @Published var selectedMode: WorkMode = .work {
        didSet {
            // Changing modes is taking a stance on what happens next, so a
            // pending "implement this plan?" prompt — or an unanswered
            // question — would only contradict it.
            if selectedMode != oldValue {
                planApprovalPending = false
                clearPendingQuestion()
            }
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
    @Published var sidebarDestination: SidebarDestination = .ask {
        didSet {
            guard sidebarDestination != oldValue else { return }
            syncInspectorWithSidebarDestination()
        }
    }
    /// The agent selected as a whole in the sidebar. This is deliberately
    /// independent of the open chat: selecting an agent changes its inspector
    /// and New Chat target without replacing the conversation in the centre.
    @Published var selectedAgentID: String?
    /// Only `selectInspectorTab(_:)` may change this. Backend events set a
    /// badge instead, so a run can never yank the panel out from under you.
    @Published var inspectorTab: InspectorTab = .plan  // internal(for: AppModel+UITestFixtures)
    /// Ordered, de-duplicated tabs currently kept open in the inspector.
    /// Selection and closure flow through the methods in the Inspector section
    /// so persistence and fallback behavior cannot drift apart.
    @Published var openInspectorTabs: [InspectorTab] = [] {  // internal(for: AppModel+UITestFixtures)
        didSet {
            settings.inspectorOpenTabs = openInspectorTabs.map(\.rawValue)
        }
    }
    /// Session-local destination for the rail's reopen control. Persistence
    /// continues to describe tabs that are actually open; a fresh launch has
    /// no closed-tab history and therefore falls back to Overview.
    var lastClosedInspectorTab: InspectorTab?  // internal(for: AppModel extension files)
    @Published var inspectorCollapsed = true {
        didSet {
            guard inspectorCollapsed != oldValue else { return }
            settings.inspectorCollapsed = inspectorCollapsed
            // Zoom is a state of the *open* panel; closing it always lands
            // back in the rail, never in a hidden-but-zoomed limbo.
            if inspectorCollapsed { setInspectorZoomed(false) }
        }
    }
    @Published var inspectorWidth: CGFloat = CGFloat(AppSettings.defaultInspectorWidth)  // internal(for: AppModel extension files)
    @Published var sidebarWidth: CGFloat = CGFloat(AppSettings.defaultSidebarWidth)  // internal(for: AppModel extension files)
    /// The panel filling the window with chat squeezed to a column. A focus
    /// mode, deliberately not persisted — relaunch returns to the normal
    /// layout. Only `setInspectorZoomed(_:)` may change it.
    @Published var inspectorZoomed = false  // internal(for: AppModel+UITestFixtures)
    /// The chat column's width while zoomed. The panel takes the remainder,
    /// so this is the value the divider drags in that state.
    @Published var zoomedChatWidth: CGFloat = CGFloat(AppSettings.defaultZoomedChatWidth)  // internal(for: AppModel extension files)
    /// Whether un-zooming should reopen the session sidebar it auto-collapsed.
    var restoreSidebarAfterZoom = false  // internal(for: AppModel extension files)
    @Published var planHasUnseenUpdate = false  // internal(for: AppModel extension files)
    /// True between a completed Plan-mode turn that produced a plan and the
    /// user's answer to "implement this plan?". While set, the composer input
    /// is replaced by PlanApprovalPromptView, the way permission requests are.
    @Published var planApprovalPending = false  // internal(for: AppModel+UITestFixtures)
    @Published var activePlan: PlanDocument?  // internal(for: AppModel+UITestFixtures)
    /// The question a completed turn asked the user. While set, the composer
    /// input is replaced by QuestionPromptView, the way plan approval is.
    @Published var pendingUserQuestion: UserQuestion?  // internal(for: AppModel+UITestFixtures)
    /// A live question whose worker is blocked until this chat sends a
    /// `question_response`. Kept separate from the completed-turn question
    /// above so both current and older agent protocols remain compatible.
    @Published var pendingBlockingQuestion: AgentQuestionRequest?
    /// Captured from `question_ready` mid-turn; armed only when the turn
    /// completes, so an interrupted or errored turn never offers a stale
    /// question.
    var capturedQuestionThisTurn: UserQuestion?  // internal(for: AppModel extension files)
    let gitWorkspace = GitWorkspaceModel()
    let workspaceFiles = WorkspaceFileModel()
    let library = WorkspaceLibraryModel()
    let outputsLibrary = OutputsLibraryModel()
    let onboarding = OnboardingModel()
    let agentInspector = AgentInspectorModel()
    /// Deliberately not bridged into `objectWillChange`: the Notebook sheet
    /// observes this directly, and republishing here would invalidate the whole
    /// workspace view every time its list changed.
    let notebook = NotebookModel()
    let agentInstructions = AgentInstructionsModel()
    @Published var contextFiles: [ContextFile] = []
    var chatAttachments: [ChatAttachment] {
        get { composerState.attachments }
        set { composerState.attachments = newValue }
    }
    var chatAttachmentNotice: String? {
        get { composerState.attachmentNotice }
        set { composerState.attachmentNotice = newValue }
    }
    var isLoadingChatAttachments: Bool {
        get { composerState.isLoadingAttachments }
        set { composerState.isLoadingAttachments = newValue }
    }
    /// One explicitly selected Mac application per task. Stored only in
    /// memory; reconnects and app relaunches require a fresh scoped consent.
    @Published var liveApplicationTargets: [String: ApplicationTarget] = [:]  // internal(for: AppModel extension files)
    @Published var checkpoints: [SessionCheckpoint] = []
    var workspaceProfiles: [WorkspaceProfile] {
        get { sessionCatalog.snapshot.workspaceProfiles }
        set { sessionCatalog.replaceWorkspaceProfiles(newValue) }
    }
    var draftText: String {
        get { composerState.draftText }
        set { composerState.draftText = newValue }
    }
    @Published var promptHistory: [String] = []
    var queuedMessages: [String] {
        get { composerState.queuedMessages }
        set { composerState.queuedMessages = newValue }
    }
    @Published var shortcutsPresented = false
    @Published var sidebarCollapsed = false {
        didSet {
            guard sidebarCollapsed != oldValue else { return }
            settings.sidebarCollapsed = sidebarCollapsed
        }
    }
    @Published var settings: AppSettings {
        didSet {
            transcriptPresentation.setPresentationVisibility(
                toolActivity: settings.resolvedToolActivityVisibility,
                thinking: settings.resolvedThinkingVisibility
            )
            scheduleWorkspacePersistence()
            // Without this, anything a view writes into `settings` is lost on
            // relaunch: the only other writer is applySettings(), so the
            // preview URL — and now the inspector chrome — never persisted.
            scheduleSettingsPersistence()
        }
    }
    /// A settings-window-only appearance override. It drives every scene while
    /// the picker is being edited without writing the draft to disk.
    @Published var appearancePreview: AppAppearance?  // internal(for: AppModel extension files)
    var effectiveAppearance: AppAppearance {
        appearancePreview ?? settings.resolvedAppearance
    }
    var effectiveAccent: LocusAccentSelection { settings.resolvedAccent }
    var accentActionColor: Color { effectiveAccent.actionColor }
    @Published var settingsPresented = false
    @Published var launchAtLoginError: String?  // internal(for: AppModel extension files)
    @Published var automaticInspectorPrompt: AutomaticInspectorPrompt?  // internal(for: AppModel extension files)
    @Published var usageDashboardPresented = false
    @Published var configureAgentPresented = false
    @Published var configureAgentTab: ConfigureAgentTab = .configurations
    /// A configuration the sheet should select once its lists have loaded,
    /// keyed the way the sheet keys them ("event:<id>", "price:<id>",
    /// "schedule:<id>"). The sheet clears it after applying it.
    @Published var configureAgentFocusConfigurationID: String?
    /// A trigger editor to open once the sheet is mounted — the same
    /// handshake the schedule editor uses, because the editor is a sheet of
    /// the sheet and cannot be presented before its host exists.
    @Published var configureAgentPendingTriggerEdit: PendingEventTriggerEdit?
    /// A snapshot of the composer taken when Configure Agent opens. The live
    /// composer remains untouched while the user decides whether to reuse it.
    @Published var configureAgentDraftSuggestion = ""
    @Published var configureAgentPendingScheduleDraft: ScheduleEditorDraft?
    @Published var lastModelRoutingDecision: ModelRoutingDecision?  // internal(for: AppModel extension files)
    @Published var modelRouterMessage = "No scorecard has been run yet."  // internal(for: AppModel extension files)
    @Published var proxyHealthRecords: [ProxyHealthRecord] = []  // internal(for: AppModel extension files)
    @Published var proxyHealthMessage = "Proxy health has not been checked yet."  // internal(for: AppModel extension files)
    @Published var isCheckingProxyHealth = false  // internal(for: AppModel extension files)
    @Published var settingsPage: SettingsPage = .general
    @Published var modelLibraryPresented = false
    private var modelLibraryPendingSettingsDismissal = false
    @Published var commandPalettePresented = false
    @Published var checkpointPresented = false
    @Published var notebookPresented = false
    /// A workspace file opened for reading in the large viewer sheet.
    @Published var fileViewerRequest: WorkspaceFileViewerRequest?
    @Published var rememberConfirmationText: String?
    @Published var clearChatConfirmationPresented = false
    @Published var clearSessionsConfirmationPresented = false
    @Published var isClearingSessions = false
    @Published var retryingRunIDs: Set<String> = []  // internal(for: AppModel extension files)
    @Published var clearingAttentionRunIDs: Set<String> = []  // internal(for: Attention actions)
    @Published var isClearingUnavailableAttention = false
    @Published var clearingChatWarningSessionIDs: Set<String> = []  // internal(for: sidebar actions)
    var showArchivedSessions: Bool {
        get { sessionCatalog.snapshot.showArchivedSessions }
        set { sessionCatalog.setShowArchivedSessions(newValue) }
    }
    var searchQuery: String {
        get { sessionCatalog.snapshot.searchQuery }
        set { sessionCatalog.setSearchQuery(newValue) }
    }
    let transcriptSearch = TranscriptSearchModel()
    var sidebarSearchFocusToken: UUID {
        get { sessionCatalog.snapshot.sidebarSearchFocusToken }
        set { sessionCatalog.replaceSidebarSearchFocusToken(newValue) }
    }
    @Published var globalNewFolderPresented = false
    @Published var globalNewFolderName = ""
    var composerFocusToken: UUID {
        get { composerState.focusToken }
        set { composerState.focusToken = newValue }
    }
    private var pendingSearchHit: TranscriptSearchHit?
    var expandedWorkspaceIDs: Set<String> {
        get { sessionCatalog.snapshot.expandedWorkspaceIDs }
        set { sessionCatalog.replaceExpandedWorkspaceIDs(newValue) }
    }
    @Published var transcriptSearchPresented = false
    @Published var transcriptSearchQuery = "" {
        didSet { transcriptSearchSelection = 0 }
    }
    @Published var transcriptSearchSelection = 0
    /// A one-shot destination requested by the session overview activity feed.
    /// ConversationView owns the actual scrolling so the overview never reaches
    /// through to transcript UI state.
    @Published var transcriptJumpTarget: UUID?
    @Published var streamRevision = 0
    let toastCenter = ToastCenter()
    var toastMessage: String? { toast?.message }
    @Published var lifecycleRecoveryMessage: String?  // internal(for: AppModel+UITestFixtures)
    @Published var backendLogHint = ""
    @Published var contextNotice: String?
    @Published var isLoadingContext = false
    /// App-owned PTY state. A `let` on its own ObservableObject keeps terminal
    /// title/lifecycle publications from redrawing the conversation.
    let terminal = TerminalSession()
    let computerControl = ComputerControlService()
    let applicationContext = ApplicationContextService()
    let simulatorControl = SimulatorControlService()
    let eventAutomations: EventAutomationModel
    private var applicationContextCapabilityObservation: AnyCancellable?
    /// The browser, for the same reason as the terminal: its tab list and load
    /// progress change far too often to republish AppModel over.
    let browser: BrowserService
    #if LOCUS_WALLET
    lazy var walletGateway = WalletGateway()
    #endif
    let streamingReply = StreamingReplyState()
    /// Provider-neutral, event-sourced state consumed by the Overview inspector.
    let sessionOverview = SessionStateEmitter()

    let backend: BackendService  // internal(for: AppModel extension files)
    let credentialStore: any CredentialStoring
    let providerCredentialWriter: (String, String) -> Bool  // internal(for: AppModel extension files)
    let backendProcess = BackendProcess()  // internal(for: AppModel extension files)
    var taskWorkers: [String: ChatWorkerRuntime] = [:]  // internal(for: AppModel extension files)
    var chatAdmissionQueue = ChatAdmissionQueue()  // internal(for: AppModel extension files)
    var pendingChatTurns: [String: Task<Void, Never>] = [:]  // internal(for: AppModel extension files)
    var pendingChatTurnTokens: [String: UUID] = [:]  // internal(for: AppModel extension files)
    var pendingSimulatorActions: [String: (sessionID: String, task: Task<Void, Never>)] = [:]  // internal(for: AppModel extension files)
    /// Backends that refused the browser handshake because a turn was running.
    var pendingBrowserCapabilityTransports: [BackendService] = []  // internal(for: AppModel extension files)
    var pendingMainConnectorCapabilitySync = false  // internal(for: AppModel extension files)
    var conversationBackend: BackendService {  // internal(for: AppModel extension files)
        taskWorkers[currentSessionID]?.service ?? backend
    }

    /// Team chats execute in dedicated worker processes. Run controls must go
    /// back to the worker that owns the run; sending them to the main control
    /// service can update the shared run database without interrupting the
    /// model call, which makes a cancelled approval reappear on reconnect.
    func orchestrationBackend(for runID: String) -> BackendService {
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

    func runRecord(for runID: String) -> OrchestrationRun? {
        if selectedOrchestrationRun?.id == runID { return selectedOrchestrationRun }
        if let detail = runDetailsByID[runID] { return detail }
        return orchestrationRuns.first(where: { $0.id == runID })
    }

    func runKind(for runID: String) -> String {
        if turnDispatchedTeamRunID == runID { return "team" }
        return runRecord(for: runID)?.runKind ?? "solo"
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
    let ollamaRuntime = OllamaRuntime()  // internal(for: AppModel extension files)
    let workspaceAccess: WorkspaceAccess  // internal(for: AppModel extension files)
    var initialWorkspacePath: String?  // internal(for: AppModel extension files)
    var streamingAssistantID: UUID?  // internal(for: AppModel extension files)
    var pendingTokens = ""  // internal(for: AppModel extension files)
    var pendingReasoning = ""  // internal(for: AppModel extension files)
    var pendingReasoningSections: [Int: String] = [:]  // internal(for: AppModel extension files)
    /// Rough size of the reply streamed since the last `session_info`, so the
    /// context meter moves during a turn instead of freezing at the pre-turn
    /// value. Reset whenever the backend supplies a real count.
    var streamedCharsThisTurn = 0  // internal(for: AppModel extension files)
    lazy var streamFlushDriver = DisplaySynchronizedFlushDriver { [weak self] in
        self?.flushPendingTokens()
    }
    var refreshTask: Task<Void, Never>?  // internal(for: AppModel extension files)
    var runtimeRecoveryTask: Task<Void, Never>?  // internal(for: AppModel extension files)
    var runtimeRecoveryAttempt = 0  // internal(for: AppModel extension files)
    var proxyHealthMonitorTask: Task<Void, Never>?  // internal(for: AppModel extension files)
    var proxyRouteRestartPending = false  // internal(for: AppModel extension files)
    var restoredTranscriptContext: String?  // internal(for: AppModel extension files)
    var pendingDeletedChat: DeletedChatUndo?  // internal(for: AppModel extension files)
    var profilePersistenceTask: Task<Void, Never>?  // internal(for: AppModel extension files)
    var settingsPersistenceTask: Task<Void, Never>?  // internal(for: AppModel extension files)
    var promptHistoryCursor: Int?  // internal(for: AppModel extension files)
    var stashedDraft: String?  // internal(for: AppModel extension files)
    var pendingSessionReset = false  // internal(for: AppModel extension files)
    /// Whether the turn in flight rewrote the todo list. The approval prompt
    /// is offered only for turns that actually produced a plan — a Plan-mode
    /// chat answer must not re-offer a plan left over from an earlier run.
    var planTodosChangedThisTurn = false  // internal(for: AppModel extension files)
    var planReadyThisTurn = false  // internal(for: AppModel extension files)
    /// What the user actually dispatched, kept separate from the live picker
    /// so a mid-run mode change cannot relabel the completion marker or alter
    /// plan reconciliation.
    var turnDispatchedMode: WorkMode?
    var turnDispatchedTeamRunID: String?  // internal(for: AppModel extension files)
    /// Client-side fallback for agents from before `turn_done.duration_ms`.
    var turnStartedAt: Date?  // internal(for: AppModel extension files)
    /// The window during which file activity counts as this run's output, and
    /// the session it belongs to.
    ///
    /// Gating on `status == .running` lost work at both ends: git status is an
    /// async round trip, so a response about the very files the run produced
    /// routinely lands after `.runFinished` has already flipped the state to
    /// idle. Capturing the session id here also stops a mid-run switch from
    /// filing one chat's outputs under another's.
    var fileCaptureSessionID = ""  // internal(for: AppModel extension files)
    var fileCaptureStartedAt = 0  // internal(for: AppModel extension files)
    var fileCaptureUntil = 0  // internal(for: AppModel extension files)
    let sessionOutputWatcher = SessionOutputWatcher()  // internal(for: AppModel extension files)
    var sessionOutputWatchTeardown: Task<Void, Never>?  // internal(for: AppModel extension files)
    /// Present only for solo turns that the optional model router prepared.
    /// Keeping these per session matters because a routed chat can finish after
    /// the user has switched to, or started, another conversation.
    var automaticModelRoutingTurns: [String: ModelRoutingPreparedTurn] = [:]  // internal(for: AppModel extension files)
    /// Keeps workspace persistence pinned to the user's manual choice while a
    /// slower hosted-provider switch restores that choice after opt-out.
    var isRestoringManualModelRoute = false  // internal(for: AppModel extension files)
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
    var pendingRetry = false  // internal(for: AppModel extension files)
    /// Stop & Send is deliberately not part of the ordinary queue: it must
    /// wait for the interrupted turn's terminal event before it can create a
    /// fresh provider turn and conversation-history boundary.
    var pendingStopAndSend: String?  // internal(for: AppModel extension files)
    var pendingCheckpointRestore: SessionCheckpoint?  // internal(for: AppModel extension files)
    var pendingRewindDraft: String?  // internal(for: AppModel extension files)
    var pendingWorkspacePath: String?  // internal(for: AppModel extension files)
    var workspaceToOpenAfterReconnect: String?  // internal(for: AppModel extension files)
    var appliedWorkspacePath: String?  // internal(for: AppModel extension files)
    var sessionResetWatchdog: Task<Void, Never>?  // internal(for: AppModel extension files)
    /// Retains only the currently requested transcript load. Completion clears
    /// its own handle without clearing a newer request; callers may await a
    /// captured handle without changing response ordering or cancellation.
    var activeTranscriptLoad: (token: TranscriptSessionLoadToken, task: Task<Void, Never>)?
    struct PendingTranscriptTransition {
        let ownership: TranscriptSessionLoadToken
        let source: ObjectIdentifier
        let reasons: Set<String>
        var acceptsSocketAcknowledgement: Bool
    }
    var pendingTranscriptTransition: PendingTranscriptTransition?
    var terminalRefreshRunIDs: Set<String> = []  // internal(for: AppModel extension files)
    var restoredQueuedRunIDs: Set<String> = []  // internal(for: AppModel extension files)
    let lifecycleJournal: AppLifecycleJournal?  // internal(for: AppModel extension files)
    var pendingLifecycleRecovery: AppLifecycleRecovery?  // internal(for: AppModel extension files)
    private var terminationObserver: NSObjectProtocol?
    var activationObserver: NSObjectProtocol?  // internal(for: AppModel extension files)
    var wakeObserver: NSObjectProtocol?  // internal(for: AppModel extension files)
    var privacyLockObservers: [NSObjectProtocol] = []  // internal(for: AppModel extension files)
    /// False for unit and UI tests. Views check it before touching the
    /// credential file: a test must not read — or delete — the secrets of
    /// whoever is running the suite.
    let persistenceEnabled: Bool
    let isUITesting: Bool  // internal(for: AppModel extension files)
    var isShuttingDown = false  // internal(for: AppModel extension files)
    private var settingsUpdatePreparation: (
        id: UUID,
        handler: @MainActor () -> Bool
    )?

    init(
        startImmediately: Bool = true,
        backendOverride: BackendService? = nil,
        lifecycleJournal: AppLifecycleJournal? = nil,
        providerCredentialWriter: ((String, String) -> Bool)? = nil,
        credentialStore: (any CredentialStoring)? = nil,
        mcpCredentialStore: (any MCPCredentialStoring)? = nil,
        browserAutofillVault: BrowserAutofillVault? = nil,
        connectorCredentialStore: (any ConnectorCredentialStoring)? = nil
    ) {
        let isUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"
        self.isUITesting = isUITesting
        let persistenceEnabled = startImmediately && !isUITesting
        self.persistenceEnabled = persistenceEnabled
        let credentials: any CredentialStoring = credentialStore ?? (persistenceEnabled
            ? CredentialStore.shared : InMemoryCredentialStore())
        self.credentialStore = credentials
        providerAccountsModel = ProviderAccountsModel(credentialStore: credentials)
        agentTeamsModel = AgentTeamsModel(credentialStore: credentials)
        self.providerCredentialWriter = providerCredentialWriter ?? { value, account in
            credentials.set(value, account: account)
        }
        extensionsModel = ExtensionsModel(credentialStore: mcpCredentialStore ?? (persistenceEnabled
            ? KeychainMCPCredentialStore() : InMemoryMCPCredentialStore()))
        browser = BrowserService(autofillVault: browserAutofillVault ?? (persistenceEnabled
            ? BrowserAutofillVault() : BrowserAutofillVault(inMemory: ())))
        eventAutomations = EventAutomationModel(credentials: connectorCredentialStore ?? (persistenceEnabled
            ? ConnectorCredentialStore.shared : InMemoryConnectorCredentialStore()))
        let launchJournal = lifecycleJournal ?? AppLifecycleJournal()
        self.lifecycleJournal = persistenceEnabled ? launchJournal : nil
        pendingLifecycleRecovery = persistenceEnabled ? launchJournal.beginLaunch() : nil
        let defaults = UserDefaults.standard
        let existingInstallation = defaults.data(forKey: "Locus.settings") != nil
            || defaults.data(forKey: "Locus.sessionOverviewStates.v1") != nil
        activity.restore(persistenceEnabled: !isUITesting && persistenceEnabled)
        if !isUITesting, persistenceEnabled {
            if let data = defaults.data(forKey: Self.splitRestorationKey),
               let restoration = try? JSONDecoder().decode(ChatSplitRestoration.self, from: data)
            {
                chatSplitRestoration = restoration
            }
        }
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

        var restoredProviderAccounts: [ProviderAccount] = []
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
            restoredProviderAccounts = accounts
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
        agentTeamsModel.restore(
            persistenceEnabled: !isUITesting && persistenceEnabled,
            defaults: defaults
        )
        let restoredOpenInspectorTabs = loadedSettings.resolvedInspectorOpenTabs
        loadedSettings.inspectorOpenTabs = restoredOpenInspectorTabs.map(\.rawValue)
        if !loadedSettings.inspectorCollapsed, restoredOpenInspectorTabs.isEmpty {
            // An open inspector without a tab has no renderable state. This is
            // possible only through corrupt or hand-edited settings.
            loadedSettings.inspectorCollapsed = true
        }
        let initialInspectorTab = loadedSettings.resolvedRestoredInspectorTab

        let migrateLegacyBuildMode = !loadedSettings.adaptiveWorkMigrationCompleted
        loadedSettings.adaptiveWorkMigrationCompleted = true
        #if LOCUS_WALLET
        let migrateLegacyWalletFeatureAccess = loadedSettings.migrateLegacyWalletFeatureAccess(
            environment: ProcessInfo.processInfo.environment
        )
        let needsSettingsMigration = migrateLegacyBuildMode || migrateLegacyWalletFeatureAccess
        #else
        let needsSettingsMigration = migrateLegacyBuildMode
        #endif
        if needsSettingsMigration, persistenceEnabled,
           let data = try? JSONEncoder().encode(loadedSettings)
        {
            defaults.set(data, forKey: "Locus.settings")
        }
        LocusAccentRuntime.shared.configure(loadedSettings.resolvedAccent)
        settings = loadedSettings
        sessionOverview.configurePersistence(
            enabled: persistenceEnabled && !isUITesting,
            defaults: defaults
        )
        // The proxy snapshot is what static call sites read; seed it before
        // anything can make a request. A test model must not read the
        // credential file, for the same reason it must not read accounts.
        ProxyRuntime.shared.update(
            settings: loadedSettings,
            password: persistenceEnabled ? CredentialStore.proxyPassword() : nil,
            profilePasswords: persistenceEnabled
                ? CredentialStore.proxyPasswords(for: loadedSettings.allProxyProfiles) : [:],
            providerAccountID: loadedSettings.activeAccountID
        )

        if !isUITesting,
           let data = defaults.data(forKey: "Locus.checkpoints"),
           let saved = try? JSONDecoder().decode([SessionCheckpoint].self, from: data)
        {
            checkpoints = saved
        }
        var restoredWorkspaceProfiles: [WorkspaceProfile] = []
        var restoredWorkspacePaths: [String] = []
        if !isUITesting,
           let data = defaults.data(forKey: "Locus.workspaceProfiles"),
           let saved = try? JSONDecoder().decode([WorkspaceProfile].self, from: data)
        {
            let recent = saved.sorted { $0.lastOpened > $1.lastOpened }
            if migrateLegacyBuildMode {
                if persistenceEnabled,
                   let migratedData = try? JSONEncoder().encode(recent)
                {
                    defaults.set(migratedData, forKey: "Locus.workspaceProfiles")
                }
            }
            restoredWorkspaceProfiles = recent
            restoredWorkspacePaths = recent.map(\.path)
        }
        let access = WorkspaceAccess(defaults: defaults)
        workspaceAccess = access
        initialWorkspacePath = access.restoreAvailable(paths: restoredWorkspacePaths)
            ?? WorkspaceAccess.sandboxWorkspaceURL()?.path
        ProxyRuntime.shared.noteRoutingContext(
            workspacePath: initialWorkspacePath,
            providerAccountID: loadedSettings.activeAccountID
        )
        promptHistory = isUITesting ? [] : (defaults.stringArray(forKey: "Locus.promptHistory") ?? [])

        // Seeded here rather than in a didSet: assignments inside init skip
        // property observers, so this cannot echo back into persistence.
        inspectorWidth = CGFloat(loadedSettings.inspectorWidth)
        sidebarWidth = isUITesting ? 240 : CGFloat(loadedSettings.sidebarWidth)
        zoomedChatWidth = CGFloat(loadedSettings.inspectorZoomedChatWidth)
        inspectorCollapsed = loadedSettings.inspectorCollapsed
        sidebarCollapsed = loadedSettings.sidebarCollapsed
        openInspectorTabs = restoredOpenInspectorTabs
        inspectorTab = initialInspectorTab

        backend = backendOverride ?? BackendService(
            baseURL: URL(string: loadedSettings.backendURL) ?? URL(string: "http://127.0.0.1:8791")!
        )
        sessionCatalog.configure(
            persistenceEnabled: !isUITesting && persistenceEnabled,
            defaults: defaults,
            searchQueryDidChange: { [weak self] query in
                self?.transcriptSearch.scheduleHitSearch(query: query)
            }
        )
        sessionCatalog.replaceWorkspaceProfiles(restoredWorkspaceProfiles)
        sessionCatalog.setActiveWorkspacePath(
            initialWorkspacePath ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        transcriptPresentation.configure(
            toolActivityVisibility: loadedSettings.resolvedToolActivityVisibility,
            thinkingVisibility: loadedSettings.resolvedThinkingVisibility,
            pendingPermissionDidChange: { [weak self] value in
                self?.hasPendingPermission = value
            }
        )
        providerAccountsModel.providerAccounts = restoredProviderAccounts
        gitWorkspace.configure(
            backend: backend,
            isUITesting: isUITesting,
            workspacePath: { [weak self] in
                self?.workspacePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            },
            changesTabVisible: { [weak self] in
                self?.inspectorTab == .changes && self?.inspectorCollapsed == false
            },
            commitDraftContext: { [weak self] in
                GitWorkspaceModel.CommitDraftContext(
                    useLocalModel: self?.settings.provider == .ollama && self?.isModelOnline == true,
                    host: self?.ollamaHost ?? "",
                    modelName: self?.selectedModel ?? ""
                )
            },
            showToast: { [weak self] message in
                self?.showToast(message)
            },
            didApplyStatus: { [weak self] previous, current in
                self?.handleGitStatusApplied(previous: previous, current: current)
            }
        )
        workspaceFiles.configure(
            isUITesting: isUITesting,
            workspacePath: { [weak self] in
                self?.workspacePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            },
            canIndex: { [weak self] in self?.sessionInfo != nil }
        )

        backend.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.agentRuntimePhase = .online
                    self.runtimeRecoveryAttempt = 0
                    self.sendComputerControlCapability()
                    self.sendSimulatorControlCapability()
                    self.browser.defaultViewport = self.settings.resolvedBrowserViewport.size
                    self.applyBrowserSettings(self.settings)
                    self.announceBrowserCapability()
                    self.sendNotesCapability(to: self.backend)
                    #if LOCUS_WALLET
                    self.sendWalletCapability(to: self.backend)
                    #endif
                    self.sendConnectorCapability(to: self.backend)
                    self.syncPreferredPermissionMode(to: self.backend)
                    if let runID = self.orchestrationRunID {
                        Task { @MainActor [weak self] in
                            await self?.backfillOrchestrationEvents(runID)
                        }
                    }
                } else if self.agentRuntimePhase.isOnline, !self.isShuttingDown {
                    self.agentRuntimePhase = .recovering("Reconnecting to the local agent…")
                    self.recoverFromLostConnection()
                    if self.persistenceEnabled {
                        self.scheduleRuntimeRecovery(reason: "The local agent connection was lost.")
                    }
                }
            }
        }
        backend.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        applicationContextCapabilityObservation = applicationContext.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                // @Published sends before replacing its value. Recalculate on
                // the next actor turn so a terminated scoped app loses tools.
                await Task.yield()
                self?.announceComputerControlCapability()
            }
        }
        agentInstructions.configure(
            backend: backend,
            isUITesting: isUITesting,
            workspacePathProvider: { [weak self] in self?.workspacePath ?? "" },
            runIsActive: { [weak self] in
                guard let self else { return true }
                return self.isBusy || self.hasPendingPermission
            },
            toastHandler: { [weak self] message in self?.showToast(message) },
            workspaceFilesChanged: { [weak self] in self?.workspaceFiles.refresh(force: true) }
        )
        knowledge.configure(
            backend: backend,
            isUITesting: isUITesting,
            workspacePathProvider: { [weak self] in self?.workspacePath ?? "" },
            sessionAttribution: { [weak self] in
                (self?.currentSessionID ?? "", self?.orchestrationRunID)
            },
            ollamaHostProvider: { [weak self] in self?.lastOllamaHost ?? "" },
            knowledgePageVisible: { [weak self] in self?.settingsPage == .knowledge },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        evaluations.configure(
            backend: backend,
            workspacePathProvider: { [weak self] in self?.workspacePath ?? "" },
            selectedTeamIDProvider: { [weak self] in self?.selectedAgentTeamID },
            manifestProvider: { [weak self] prompt, teamID in
                self?.teamManifest(for: prompt, teamID: teamID)
            },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        extensionsModel.configure(
            backend: backend,
            isUITesting: isUITesting,
            workspacePathProvider: { [weak self] in self?.workspacePath ?? "" },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        activity.configure(
            backend: backend,
            liveAttentionProvider: { [weak self] in
                self?.liveAttentionItems() ?? []
            },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        toastCenter.onToastReplaced = { [weak self] in self?.pendingDeletedChat = nil }
        backgroundServicesModel.configure(
            transportProvider: { [weak self] in self?.conversationBackend },
            recordingSessionIDProvider: { [weak self] in self?.sessionOverview.activeSessionID ?? "" },
            websiteOutput: { [weak self] url, sessionID in
                self?.emitWebsiteOutput(url, sessionID: sessionID)
            },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        transcriptSearch.configure(backend: backend)
        schedule.configure(
            backend: backend,
            persistenceEnabled: persistenceEnabled,
            isShuttingDown: { [weak self] in self?.isShuttingDown ?? true },
            draftIssue: { [weak self] draft in self?.scheduleConfigurationIssue(for: draft) },
            taskIssue: { [weak self] task in self?.scheduleConfigurationIssue(for: task) },
            refreshMetadata: { [weak self] in await self?.refreshMetadata() },
            refreshActivity: { [weak self] in
                await self?.activity.refreshActivityRuns(announceFailure: false)
            },
            restoreQueuedRuns: { [weak self] in self?.restorePersistedQueuedRuns() },
            admitQueuedRun: { [weak self] run in
                guard let self, self.restoredQueuedRunIDs.insert(run.id).inserted else { return }
                await self.dispatchPersistedQueuedRun(run)
            },
            openRun: { [weak self] run in self?.openActivityRun(run) },
            notifyPaused: { [weak self] body in
                self?.notifyNeedsAttentionIfInactive(body: body)
            },
            toastHandler: { [weak self] message in self?.showToast(message) },
            supportsWorkflows: { [weak self] in
                self?.automationWorkflowsEnabled ?? false
            }
        )
        eventAutomations.configure(
            backend: backend,
            onQueuedRun: { [weak self] run in
                guard let self,
                      run.state == "queued",
                      self.restoredQueuedRunIDs.insert(run.id).inserted else { return }
                await self.dispatchPersistedQueuedRun(run)
            },
            canDispatchToSession: { [weak self] sessionID in
                guard let self else { return false }
                if let runtime = self.taskWorkers[sessionID],
                   runtime.occupiesExecutionSlot || !runtime.queuedMessages.isEmpty {
                    return false
                }
                if self.currentSessionID == sessionID,
                   self.isBusy || self.hasPendingPermission || !self.queuedMessages.isEmpty {
                    return false
                }
                return true
            },
            onCapabilityChanged: { [weak self] in
                self?.announceConnectorCapability()
            },
            refreshSessions: { [weak self] in
                await self?.refreshMetadata()
            },
            agentProviderRoute: { [weak self] in
                guard let self else { return [:] }
                if let account = self.activeAccount {
                    return [
                        "provider": account.kind == .chatGPT ? "chatgpt" : "remote",
                        "provider_account_id": account.id.uuidString,
                        "account_label": account.displayName,
                        "model": self.routedModel(for: account),
                    ]
                }
                return [
                    "provider": "ollama",
                    "model": self.selectedModel,
                ]
            },
            openAgentSession: { [weak self] session in
                self?.sidebarDestination = .agents
                self?.resume(session)
            },
            showMessage: { [weak self] message in self?.showToast(message) },
            notifyPaused: { [weak self] body in
                self?.notifyNeedsAttentionIfInactive(body: body)
            },
            onWarningResolved: { [weak self] runID in
                self?.clearRunWarningPresentation(runID: runID)
            },
            supportsWorkflows: { [weak self] in
                self?.automationWorkflowsEnabled ?? false
            }
        )
        providerAccountsModel.configure(
            backend: backend,
            persistenceEnabled: persistenceEnabled,
            localModelHidden: { [weak self] name in self?.isLocalModelHidden(name) ?? false },
            routedModelsProvider: { [weak self] id in
                (self?.agentProfiles ?? []).compactMap { profile in
                    profile.route.accountID == id ? profile.model : nil
                }
            },
            activeAccountProvider: { [weak self] in self?.activeAccount },
            accountRoutingDeactivated: { [weak self] id in
                guard let self, self.settings.activeAccountID == id.uuidString else { return }
                self.settings.activeAccountID = nil
                await self.applyProvider(announce: false)
            },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        providerAccountsCapabilityObservation = providerAccountsModel.objectWillChange.sink { [weak self] _ in
            self?.voiceControl.invalidateCapabilityTest()
        }
        voiceControl.configure(
            settings: { [weak self] in self?.settings ?? AppSettings() },
            cloudConfiguration: { [weak self] in self?.voiceCloudConfiguration },
            sessionID: { [weak self] in self?.currentSessionID ?? "" },
            transcript: { [weak self] text, purpose in
                self?.acceptVoiceTranscript(text, purpose: purpose) ?? false
            },
            appleNetworkConsent: { [weak self] allowed in
                self?.setAppleNetworkRecognitionConsent(allowed)
            }
        )
        agentTeamsModel.configure(
            isBusyProvider: { [weak self] in self?.isBusy ?? false },
            workspacePersistenceRequested: { [weak self] in self?.scheduleWorkspacePersistence() },
            localModelsProvider: { [weak self] in self?.localModels ?? [] },
            accountsProvider: { [weak self] in self?.providerAccounts ?? [] },
            accountModelsProvider: { [weak self] id in self?.accountModels[id] },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        runs.configure(
            backend: backend,
            sessionIDProvider: { [weak self] in self?.currentSessionID ?? "" },
            transportProvider: { [weak self] runID in
                self?.orchestrationBackend(for: runID) ?? BackendService()
            },
            liveRunID: { [weak self] in self?.orchestrationRunID },
            liveState: { [weak self] in self?.orchestrationState },
            setLiveState: { [weak self] state in self?.orchestrationState = state },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        teamRunLive.configure(
            isBusyProvider: { [weak self] in self?.isBusy ?? false },
            liveRunID: { [weak self] in self?.orchestrationRunID },
            liveState: { [weak self] in self?.orchestrationState },
            selectedRunTeamID: { [weak self] in self?.selectedOrchestrationRun?.teamID },
            teamLookup: { [weak self] id in
                self?.agentTeams.first(where: { $0.id == id })
            },
            selectedTeamProvider: { [weak self] in self?.selectedAgentTeam }
        )
        landingFlow.configure(
            backend: backend,
            isUITesting: isUITesting,
            isBusy: { [weak self] in self?.isBusy ?? false },
            hasPendingPermission: { [weak self] in self?.hasPendingPermission ?? false },
            activeTask: { [weak self] in self?.activeTaskRecord },
            setActiveTask: { [weak self] task in self?.activeTaskRecord = task },
            replaceSessionTask: { [weak self] task in
                self?.sessionInfo = self?.sessionInfo?.replacingTask(task)
            },
            sourceRunID: { [weak self] in
                guard let self else { return "" }
                return self.orchestrationRunID
                    ?? self.taskConversationStates[self.currentSessionID]?.runID ?? ""
            },
            saveCheckCommands: { [weak self] commands in
                self?.saveLandingCheckCommands(commands)
            },
            gitRefresh: { [weak self] in self?.gitWorkspace.refreshStatus() },
            toastHandler: { [weak self] message in self?.showToast(message) }
        )
        simulatorControl.capabilityDidChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.announceSimulatorControlCapability()
            }
        }

        configureLibraryFeatures()
        configureOnboarding(
            defaults: persistenceEnabled ? defaults : nil,
            existingInstallation: existingInstallation
        )


        composerState.draftDidChange = { [weak self] in
            self?.resetHistoryCursorIfEdited()
            self?.scheduleWorkspacePersistence()
        }
        browser.onUserNotice = { [weak self] notice in
            self?.showToast(notice)
        }
        if startImmediately {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.browser.autofillVault.load()
            }
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
                if self.persistenceEnabled {
                    self.scheduleRuntimeRecovery(reason: "The local agent stopped unexpectedly.")
                }
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
                    guard let self else { return }
                    Task { await self.schedule.processDueSchedules() }
                    if !self.agentRuntimePhase.isOnline || !self.modelRuntimePhase.isOnline {
                        self.scheduleRuntimeRecovery(
                            reason: "Checking local services after Locus became active.",
                            immediate: true
                        )
                    }
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.schedule.processDueSchedules() }
            }
            #if LOCUS_WALLET
            let workspaceNotifications = NSWorkspace.shared.notificationCenter
            privacyLockObservers = [
                NSWorkspace.willSleepNotification,
                NSWorkspace.screensDidSleepNotification,
                NSWorkspace.sessionDidResignActiveNotification,
            ].map { name in
                workspaceNotifications.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.walletGateway.lock()
                        self?.refreshWalletCapabilities()
                    }
                }
            }
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                await companionGateway.configure(
                    commandHandler: { [weak self] request in
                        guard let self else {
                            return .failure(
                                id: request.id, code: "not_ready",
                                message: "Locus is closing."
                            )
                        }
                        return await self.handleCompanionRequest(request)
                    },
                    eventProvider: { [weak self] in
                        self?.companionPublishedEvents() ?? []
                    },
                    stateHandler: { [weak self] state in
                        self?.companionGatewayState = state
                    }
                )
                await companionGateway.setEnabled(settings.mobileAccessEnabled)
            }
            Task { await bootstrap() }
            scheduleProxyHealthMonitoring()
        }

        #if LOCUS_WALLET
        walletGateway.configureRPCURL(loadedSettings.walletSepoliaRPCURL)
        walletGateway.applyFeatureAccess(
            walletEnabled: loadedSettings.walletAlphaEnabled,
            browserEnabled: loadedSettings.walletBrowserProviderEnabled
        )
        browser.configureWalletGateway(walletGateway)
        walletGateway.onBrowserAuthorizationNeeded = { [weak self] in
            self?.presentSettings(.wallet)
        }
        #endif
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


    /// Whether the session is running this model through this source. Both
    /// halves matter: two accounts can offer a model of the same name.
    func isCurrentRoute(account: ProviderAccount?, model: String) -> Bool {
        account?.id.uuidString == settings.activeAccountID && model == selectedModel
    }

    /// The model an agent created or repointed right now would run on: what
    /// `agentProviderRoute` actually sends, without the picker's decoration.
    /// A team is not an agent route, so its members never appear here.
    var agentRouteModel: String {
        guard let account = activeAccount else { return selectedModel }
        return routedModel(for: account)
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
        return "\(account.shortName) · \(routedModel(for: account))"
    }

    /// What an account actually routes to. `selectedModel` is whatever the
    /// agent last reported, which is still the *previous* provider's model
    /// until this account connects — pairing the two names then advertises a
    /// route that does not exist ("Kimi · gpt-5.6-sol"). Fall back to the
    /// model this account is configured to run.
    func routedModel(for account: ProviderAccount) -> String {
        if modelBelongsToAccount(selectedModel, account: account) { return selectedModel }
        if let preferred = account.preferredModel
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return preferred
        }
        return account.kind.curatedModels.first ?? selectedModel
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

    // MARK: - Reasoning effort

    /// The efforts the current route accepts, weakest first, or empty when it
    /// has no effort control. Empty is what hides the header picker.
    ///
    /// A ChatGPT plan answers for itself: its catalog is fetched from the
    /// account's own model list and already withholds efforts the helper
    /// cannot serve. Every other account falls back to the published table.
    /// Local Ollama has no account and no effort control.
    var reasoningEffortOptions: [String] {
        guard let account = activeAccount else { return [] }
        let model = routedModel(for: account)
        if account.kind == .chatGPT {
            var efforts = accountModelCatalogs[account.id]?
                .first(where: { $0.id == model })?
                .supportedReasoningEfforts?
                .map(\.effort) ?? []
            // Keep a stored choice selectable even when the catalog drops it,
            // so the picker never silently disagrees with what is being sent.
            let current = resolvedReasoningEffort
            if !current.isEmpty, !efforts.contains(current) { efforts.append(current) }
            return efforts
        }
        return account.kind.publishedReasoningEfforts(for: model)
    }

    /// The effort this route will actually request: the workspace's own choice,
    /// then the account's default, then "" for the model's default.
    ///
    /// nil and "" are different answers here. nil is a workspace that has never
    /// chosen, which defers to the account; "" is a workspace that chose Auto,
    /// which has to beat an account default or picking Auto would do nothing on
    /// the one kind of account that has one.
    var resolvedReasoningEffort: String {
        if let workspace = currentWorkspaceReasoningEffort { return workspace }
        return activeAccount?.codexReasoningEffortValue ?? ""
    }

    /// The override stored against the workspace currently open, if any.
    private var currentWorkspaceReasoningEffort: String? {
        let path = workspacePath
        return workspaceProfiles.first {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }?.reasoningEffort
    }

    /// Records the effort for this workspace and re-sends the route so the next
    /// turn uses it. Effort is applied per turn on every provider, so this never
    /// restarts a conversation — only the prompt cache pays, by re-reading the
    /// prefix once.
    func setReasoningEffort(_ effort: String) {
        guard effort != resolvedReasoningEffort else { return }
        let path = workspacePath
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            workspaceProfiles[index].reasoningEffort = effort
            persistWorkspaceProfiles()
        } else {
            // No profile yet — the workspace has not been recorded. Writing the
            // whole profile is what creates it, and it carries the effort along.
            pendingReasoningEffort = effort
            persistCurrentWorkspaceProfile()
        }
        pendingReasoningEffort = nil
        Task { _ = await applyProvider(announce: false) }
    }

    /// Carries an effort into `persistCurrentWorkspaceProfile` for a workspace
    /// that has no stored profile yet.
    var pendingReasoningEffort: String?  // internal(for: AppModel extension files)

    /// Test seam: the effort picker reads a catalog fetched from the account's
    /// own model list, and unit tests have no backend to fetch one from.
    func applyAccountModelCatalogForTesting(
        _ models: [ChatGPTModelsResponse.Model],
        for account: UUID
    ) {
        accountModelCatalogs[account] = models
    }

    func isLocalModelHidden(_ name: String) -> Bool {
        settings.hiddenLocalModels.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    var filteredSessions: [SessionSummary] {
        sessionCatalog.snapshot.filteredSessions
    }

    static let otherWorkspaceID = SessionCatalogModel.otherWorkspaceID

    var activeWorkspaceID: String {
        SessionSummary.canonicalWorkspacePath(workspacePath)
    }

    var chatNavigationDisabled: Bool {
        false
    }

    /// Folder-backed workspace sections plus a compatibility bucket for old
    /// transcripts whose meta record predates cwd provenance.
    var workspaceChatGroups: [WorkspaceChatGroup] {
        sessionCatalog.snapshot.sidebarGroups.map(\.group)
    }

    func folders(in group: WorkspaceChatGroup, parentID: String? = nil) -> [ChatFolderRecord] {
        guard let sidebarGroup = sessionCatalog.snapshot.sidebarGroups.first(where: {
            $0.id == group.id
        }) else { return [] }
        if let parentID {
            return Self.folderNode(id: parentID, in: sidebarGroup.rootFolders)?
                .children.map(\.folder) ?? []
        }
        return sidebarGroup.rootFolders.map(\.folder)
    }

    func chats(in group: WorkspaceChatGroup, folderID: String?) -> [SessionSummary] {
        guard let sidebarGroup = sessionCatalog.snapshot.sidebarGroups.first(where: {
            $0.id == group.id
        }) else { return [] }
        guard let folderID else { return sidebarGroup.unfiledChats }
        return Self.folderNode(id: folderID, in: sidebarGroup.rootFolders)?.chats ?? []
    }

    private static func folderNode(
        id: String,
        in nodes: [SessionSidebarFolderSnapshot]
    ) -> SessionSidebarFolderSnapshot? {
        for node in nodes {
            if node.id == id { return node }
            if let match = folderNode(id: id, in: node.children) { return match }
        }
        return nil
    }

    func teamRunState(for session: SessionSummary) -> TeamRunState? {
        if let snapshot = taskConversationStates[session.id] {
            if activity.warningIsAcknowledged(snapshot.runID) { return nil }
            return snapshot.state
        }
        if session.id == currentSessionID, let orchestrationState {
            if activity.warningIsAcknowledged(orchestrationRunID) { return nil }
            return orchestrationState
        }
        return session.task?.state
    }

    func chatIsRunning(_ session: SessionSummary) -> Bool {
        guard let state = taskWorkers[session.id]?.executionState else { return false }
        return [.running, .dispatching, .reviewing].contains(state)
    }

    func chatStartedAt(_ session: SessionSummary) -> Date? {
        taskWorkers[session.id]?.startedAt
    }

    func chatHasActiveRun(_ session: SessionSummary) -> Bool {
        pendingChatTurns[session.id] != nil
            || taskWorkers[session.id]?.occupiesExecutionSlot == true
    }

    func isWorkspaceExpanded(_ id: String) -> Bool {
        sessionCatalog.snapshot.expandedWorkspaceIDs.contains(id)
    }

    func setWorkspaceExpanded(_ id: String, expanded: Bool) {
        sessionCatalog.setWorkspaceExpanded(id, expanded: expanded)
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

    /// Bridged into settings so the choice persists; views observe it through
    /// the published `settings`.
    var thinkingVisibility: ThinkingVisibility {
        get { settings.resolvedThinkingVisibility }
        set { settings.thinkingVisibilityRaw = newValue.rawValue }
    }

    /// App-wide transcript density for tool activity. Like reasoning
    /// visibility, changing it is immediate and persists through `settings`.
    var toolActivityVisibility: ToolActivityVisibility {
        get { settings.resolvedToolActivityVisibility }
        set { settings.toolActivityVisibilityRaw = newValue.rawValue }
    }

    var showTeamProgressInHeader: Bool {
        get { settings.showTeamProgressInHeader }
        set { settings.showTeamProgressInHeader = newValue }
    }

    var showContextUsageInHeader: Bool {
        get { settings.showContextUsageInHeader }
        set { settings.showContextUsageInHeader = newValue }
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

    var awaitingUserDecision: Bool {
        hasPendingPermission || pendingBlockingQuestion != nil
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
            if toolActivityVisibility == .hidden { return "Action needs approval" }
            return "Waiting for permission · \(request.tool)"
        }
        if let tool = blocks.reversed().compactMap(\.tool).first(where: {
            $0.status == .running || $0.status == .awaitingPermission
        }) {
            if toolActivityVisibility == .hidden {
                return tool.status == .running ? "Working…" : "Action needs approval"
            }
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

    /// The Settings view owns staged text fields, so it registers the one
    /// synchronous validation/apply closure that an updater relaunch may need.
    /// A token prevents an older disappearing view from unregistering a newer
    /// Settings window during SwiftUI scene replacement.
    func registerSettingsUpdatePreparation(
        id: UUID,
        handler: @escaping @MainActor () -> Bool
    ) {
        settingsUpdatePreparation = (id, handler)
    }

    func unregisterSettingsUpdatePreparation(id: UUID) {
        guard settingsUpdatePreparation?.id == id else { return }
        settingsUpdatePreparation = nil
    }

    func prepareOpenSettingsForUpdate() -> Bool {
        settingsUpdatePreparation?.handler() ?? true
    }

    func backendIsHealthy() async -> Bool {
        guard BackendProcess.loopbackPortIsListening(at: backend.currentBaseURL) else {
            return false
        }
        return (try? await backend.get("/api/health", as: HealthResponse.self)) != nil
    }


}
