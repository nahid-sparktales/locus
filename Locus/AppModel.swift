import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionPhase: Equatable {
        case starting
        case connected
        case disconnected(String)
    }

    @Published var connectionPhase: ConnectionPhase = .starting
    @Published var ollamaOnline = false
    @Published var ollamaErrorMessage: String?
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
    @Published var selectedMode: WorkMode = .build {
        didSet {
            // Changing modes is taking a stance on what happens next, so a
            // pending "implement this plan?" prompt would only contradict it.
            if selectedMode != oldValue { planApprovalPending = false }
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
    @Published var contextFiles: [ContextFile] = []
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
    @Published var modelLibraryPresented = false
    @Published var commandPalettePresented = false
    @Published var checkpointPresented = false
    @Published var clearChatConfirmationPresented = false
    @Published var clearSessionsConfirmationPresented = false
    @Published var isClearingSessions = false
    @Published var showArchivedSessions = false
    @Published var searchQuery = ""
    @Published var transcriptSearchPresented = false
    @Published var transcriptSearchQuery = "" {
        didSet { transcriptSearchSelection = 0 }
    }
    @Published var transcriptSearchSelection = 0
    @Published var previewReloadID = UUID()
    @Published var streamRevision = 0
    @Published var toastMessage: String?
    @Published var backendLogHint = ""
    @Published var contextNotice: String?
    @Published var isLoadingContext = false

    /// Console state. A `let` on its own ObservableObject, not @Published
    /// here: republishing AppModel on every output chunk would redraw the
    /// sidebar, conversation and composer at the command's output rate.
    let terminal = TerminalSession()

    private let backend: BackendService
    private let backendProcess = BackendProcess()
    private let workspaceAccess: WorkspaceAccess
    private var initialWorkspacePath: String?
    private var streamingAssistantID: UUID?
    private var pendingTokens = ""
    /// Rough size of the reply streamed since the last `session_info`, so the
    /// context meter moves during a turn instead of freezing at the pre-turn
    /// value. Reset whenever the backend supplies a real count.
    private var streamedCharsThisTurn = 0
    private var streamFlushTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var restoredTranscriptContext: String?
    private var toastTask: Task<Void, Never>?
    private var profilePersistenceTask: Task<Void, Never>?
    private var settingsPersistenceTask: Task<Void, Never>?
    private var promptHistoryCursor: Int?
    private var stashedDraft: String?
    private var pendingSessionReset = false
    /// Whether the turn in flight rewrote the todo list. The approval prompt
    /// is offered only for turns that actually produced a plan — a Plan-mode
    /// chat answer must not re-offer a plan left over from an earlier run.
    private var planTodosChangedThisTurn = false
    /// Whether the turn in flight was dispatched in Plan mode. The approval
    /// offer is keyed to this latch, not the live picker — switching modes
    /// while a Build run streams must not turn that run's todo bookkeeping
    /// into an "implement this plan?" offer. Internal so tests can dispatch
    /// turns without a live backend.
    var turnDispatchedInPlanMode = false
    private var pendingRetry = false
    private var pendingCheckpointRestore: SessionCheckpoint?
    private var pendingRewindDraft: String?
    private var pendingWorkspacePath: String?
    private var appliedWorkspacePath: String?
    private var sessionResetWatchdog: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var gitStatusTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var commitDraftTask: Task<Void, Never>?
    private var filePreviewTask: Task<Void, Never>?
    private var indexedWorkspacePath: String?
    private var terminationObserver: NSObjectProtocol?
    private let persistenceEnabled: Bool
    private let isUITesting: Bool

    init(startImmediately: Bool = true) {
        let isUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"
        self.isUITesting = isUITesting
        persistenceEnabled = startImmediately && !isUITesting
        let defaults = UserDefaults.standard
        var loadedSettings: AppSettings
        if !isUITesting,
           let data = defaults.data(forKey: "Locus.settings"),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            loadedSettings = saved
        } else {
            loadedSettings = AppSettings()
        }

        if !isUITesting {
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
            // same guard covers an empty read: a container reset clears
            // UserDefaults while the keychain survives, and that must not be
            // read as "every account was deleted".
            if persistenceEnabled,
               let stored = ProviderAccountStore.storedCount(in: defaults),
               stored == accounts.count
            {
                Keychain.removeOrphanedProviderKeys(
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
        settings = loadedSettings

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
            let recent = Array(saved.sorted { $0.lastOpened > $1.lastOpened }.prefix(8))
            workspaceProfiles = recent
            restoredWorkspacePaths = recent.map(\.path)
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
                    self.connectionPhase = .connected
                } else if case .connected = self.connectionPhase {
                    self.connectionPhase = .disconnected("Reconnecting to the local agent…")
                    self.recoverFromLostConnection()
                }
            }
        }
        backend.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        terminal.transport = self

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

    private var lastOllamaHost = "http://127.0.0.1:11434"
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

    var includedContextTokens: Int {
        contextFiles.filter { $0.isIncluded && $0.isAvailable }.reduce(0) {
            $0 + $1.estimatedTokens
        }
    }

    var includedContextCount: Int {
        contextFiles.filter { $0.isIncluded && $0.isAvailable }.count
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
        connectionPhase = .starting
        if !(await backendIsHealthy()), settings.launchBackendAutomatically {
            let port = URL(string: settings.backendURL)?.port ?? 8791
            let started = backendProcess.start(
                root: settings.backendRoot,
                port: port,
                cwd: workspacePath
            )
            backendLogHint = started
                ? "Started the bundled local agent service."
                : "Could not find the agent backend at \(settings.backendRoot)."

            if started {
                // Up to 15s: a previous agent releasing the port, or a cold
                // Python start, can take longer than a couple of seconds.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if await backendIsHealthy() { break }
                }
            }
        }

        guard await backendIsHealthy() else {
            connectionPhase = .disconnected(
                "Local agent unavailable. Check the backend path in Settings."
            )
            return
        }

        // The app is the source of truth for the provider: the agent persists
        // its last choice (never the API key), so both the remote key and a
        // switch back to local have to be re-applied on every launch.
        await applyProvider(announce: false)
        await refreshMetadata()
        requestNotificationAuthorization()
        backend.connect()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.refreshMetadata()
            }
        }
    }

    func shutdown() {
        persistCurrentWorkspaceProfile()
        // Flush rather than cancel: a debounced settings write that is still
        // pending at quit would otherwise be dropped.
        persistSettings()
        refreshTask?.cancel()
        streamFlushTask?.cancel()
        profilePersistenceTask?.cancel()
        settingsPersistenceTask?.cancel()
        sessionResetWatchdog?.cancel()
        indexTask?.cancel()
        backend.disconnect()
        backendProcess.stop()
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
            ollamaOnline = health.ollama
            ollamaErrorMessage = health.error
        } catch {
            ollamaOnline = false
            ollamaErrorMessage = error.localizedDescription
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
            let suffix = showArchivedSessions ? "?include_archived=true" : ""
            let response = try await backend.get("/api/sessions\(suffix)", as: SessionsResponse.self)
            sessions = response.sessions
            currentSessionID = response.current
        } catch {
            // Preserve the last-known list during reconnects.
        }

        refreshGitBranch()
    }

    /// Reads the local runtime directly. With an account active the agent has
    /// no Ollama client to ask, but the local models still belong in the picker.
    private func refreshLocalModels() async {
        guard let url = URL(string: lastOllamaHost + "/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else { return }  // Ollama not running is normal; keep the last list.
        localModels = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ModelInfo(
                name: name,
                size: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: (entry["details"] as? [String: Any])?["parameter_size"] as? String ?? "",
                contextLength: 0
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
        guard !text.isEmpty else { return }

        // Slash commands that Locus can run itself execute immediately, even
        // mid-run; anything else starting with "/" goes to the agent verbatim.
        if let command = SlashCommand.command(invokedBy: text) {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            recordPrompt(text)
            execute(command, argument: SlashCommand.argument(in: text))
            return
        }

        if isBusy || hasPendingPermission {
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
        guard case .connected = connectionPhase else {
            stashUnsent(text, requeue: requeueingOnFailure, preserveDraft: preservingDraftOnFailure)
            return
        }

        let isSlashPassthrough = SlashCommand.query(from: text) != nil
        isBusy = true
        planApprovalPending = false
        planTodosChangedThisTurn = false
        // Agent-side slash commands (/init and friends) may write todos, but
        // running one is housekeeping, never a plan worth offering to build.
        turnDispatchedInPlanMode = selectedMode == .plan && !isSlashPassthrough
        Task { [weak self] in
            guard let self else { return }
            await refreshContextFiles()
            let payload = isSlashPassthrough ? text : decoratedPrompt(text)
            guard backend.send(["type": "user_message", "text": payload]) else {
                isBusy = false
                stashUnsent(text, requeue: requeueingOnFailure, preserveDraft: preservingDraftOnFailure)
                return
            }
            blocks.append(ChatBlock(kind: .user, text: text))
            recordPrompt(text)
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            if selectedMode == .plan { selectInspectorTab(.plan) }
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
        guard case .connected = connectionPhase,
              backend.send(["type": "user_message", "text": text])
        else {
            showToast("Reconnect the local agent to run \(text)")
            return
        }
        isBusy = true
        planApprovalPending = false
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = false
        blocks.append(ChatBlock(kind: .user, text: text))
    }

    func submitDraft() {
        send(draftText)
    }

    func removeQueuedMessage(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    private func drainQueuedMessages() {
        guard !isBusy, !hasPendingPermission, !queuedMessages.isEmpty else { return }
        guard case .connected = connectionPhase else { return }
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
        planApprovalPending = false
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = selectedMode == .plan
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
            showToast("Switched to \(mode.rawValue.capitalized) mode")
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
            model: selectedModel
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
            selectModel(model)
            if let account { rememberPreferredModel(model, for: account) }
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
            Keychain.set(apiKey, account: updated.keychainAccount)
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
        Keychain.remove(account: account.keychainAccount)
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
        Keychain.remove(account: account.keychainAccount)
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
                let suffix = showArchivedSessions ? "?include_archived=true" : ""
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
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/\(session.id)/resume",
                    body: [:],
                    as: ResumeResponse.self
                )
                flushPendingTokens()
                streamingAssistantID = nil
                isBusy = false
                todos = []
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
        if backendProcess.isRunning, WorkspaceAccess.isSandboxed {
            backend.disconnect()
            sessionInfo = nil
            Task { [backendProcess] in
                await backendProcess.stopAndWait()
                await self.bootstrap()
            }
            showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        guard backend.send(["type": "set_cwd", "path": path]) else {
            pendingWorkspacePath = nil
            showToast("Reconnect before switching workspaces")
            return
        }
        showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func removeWorkspaceProfile(_ path: String) {
        workspaceProfiles.removeAll { $0.path == path }
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
            model: selectedModel
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
        guard case .connected = connectionPhase else {
            showToast("Reconnect the local agent to create a plan")
            return
        }
        selectedMode = .plan
        send(prompt, preservingDraftOnFailure: false)
    }

    /// Answers the "implement this plan?" prompt that follows a completed
    /// Plan-mode turn. Implementing switches to Build mode and starts the
    /// run; auto-accepting also raises Ask permissions to Accept Edits so
    /// the build is not interrupted for every file change.
    func resolvePlanApproval(_ decision: PlanApprovalDecision) {
        guard planApprovalPending else { return }
        switch decision {
        case .keepPlanning:
            planApprovalPending = false
        case .implementAutoAccepting, .implementReviewing:
            guard case .connected = connectionPhase else {
                showToast("Reconnect the local agent to implement the plan")
                return
            }
            planApprovalPending = false
            selectedMode = .build
            let escalate = decision == .implementAutoAccepting && permissionMode == .ask
            Task { [weak self] in
                guard let self else { return }
                // The escalation lands before the run starts; if it fails,
                // the run still proceeds and simply asks per edit — the
                // failure toast says why. If delivery of the message itself
                // fails, it is requeued and drained on reconnect rather
                // than dropped, so the decision survives.
                if escalate { await changePermissionMode(.acceptEdits) }
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

    func applySettings(_ newSettings: AppSettings) {
        let backendChanged = settings.backendURL != newSettings.backendURL
            || settings.backendRoot != newSettings.backendRoot
        // Accounts are applied as they are edited, so the only routing change
        // that can arrive with the draft is a different active account.
        let providerChanged = settings.provider != newSettings.provider
            || settings.activeAccountID != newSettings.activeAccountID
            // The window rides the provider call, so a change to it alone
            // still has to be pushed or it never reaches the agent.
            || settings.localContextWindow != newSettings.localContextWindow
        settings = newSettings
        persistSettings()
        settingsPresented = false

        if backendChanged, let url = URL(string: newSettings.backendURL) {
            backend.updateBaseURL(url)
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
            previewReloadID = UUID()
        }
        showToast("Settings saved")
    }

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
            "api_key": Keychain.get(account: account.keychainAccount) ?? "",
            "auth_style": account.kind.authStyle,
            "account_label": account.displayName,
            // Kimi Code serves no model listing; without this the agent's
            // health probe reads its auth error on /models as a rejected
            // key and reports a working account as permanently offline.
            "lists_models": account.kind.listsModels,
            // A hosted endpoint advertises no window, so without this the meter
            // is dead and auto-compaction never engages for the account.
            "context_window": account.resolvedContextWindow ?? 0,
            "verify": verify,
        ]
    }

    /// Pushes the chosen provider to the local agent. The API key travels from
    /// the keychain to the agent process only — it is never written to disk by
    /// either side, so it is re-sent on every launch.
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
            await refreshMetadata()
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

    /// Labels only fit alongside five icons once the panel is this wide.
    var inspectorShowsLabels: Bool { inspectorWidth >= 440 }

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
        let useLocalModel = settings.provider == .ollama && ollamaOnline
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
        settings.inspectorLastTab = tab.rawValue
    }

    func toggleInspector() {
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
        guard let account = activeAccount else {
            return ollamaOnline ? "Ollama ready" : "Ollama offline"
        }
        let name = account.kind == .custom ? "Endpoint" : account.kind.marketingName
        return ollamaOnline ? "\(name) ready" : "\(name) offline"
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

    private func backendIsHealthy() async -> Bool {
        (try? await backend.get("/api/health", as: HealthResponse.self)) != nil
    }

    private func decoratedPrompt(_ text: String) -> String {
        var sections = [
            "[Locus mode: \(selectedMode.rawValue.capitalized)]",
            selectedMode.instruction,
        ]

        let included = contextFiles.filter { $0.isIncluded && $0.isAvailable }
        if !included.isEmpty {
            let context = included.map {
                """
                --- \($0.displayPath) ---
                \($0.content)
                """
            }.joined(separator: "\n\n")
            sections.append("Use this explicitly selected context:\n\(context)")
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
                sessionInfo = info
                currentSessionID = info.sessionID
                // Only when a reply is not mid-flight. `approx_tokens` counts
                // the assistant message once it has been committed, which
                // happens at message_end — the same moment streamingAssistantID
                // clears. A session_info arriving before that (changing
                // permission mode does it, and it is busy-guarded on neither
                // side) does not include the text streamed so far, so clearing
                // the estimate would drop it and the meter would visibly fall.
                if streamingAssistantID == nil { streamedCharsThisTurn = 0 }
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
            if let id = streamingAssistantID,
               let index = blocks.firstIndex(where: { $0.id == id })
            {
                blocks[index].isStreaming = false
            }
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
                // An in-place upgrade changes neither the block count nor the
                // stream revision, so without this the conversation would not
                // scroll the prompt into view.
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
            // Native reasoning output is surfaced separately from the answer;
            // it is rendered from the assistant block, so nothing to append.
            break

        case "todo_update":
            if let raw = event["todos"] as? [[String: Any]] {
                todos = raw.compactMap { decode(TodoItem.self, from: $0) }
                if todos.isEmpty {
                    // A prompt offering to implement zero steps is nonsense;
                    // the agent emptying the list withdraws the plan.
                    planApprovalPending = false
                } else {
                    planTodosChangedThisTurn = true
                }
                // Badge rather than switch: being pulled off the tab you are
                // reading mid-run is the complaint this replaces.
                if !todos.isEmpty, inspectorTab != .plan || inspectorCollapsed {
                    planHasUnseenUpdate = true
                }
            }

        case "turn_done":
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            isBusy = false
            pendingRetry = false
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            // A Plan-mode turn that wrote a plan ends by asking whether to
            // implement it — but only a finished turn, only a turn that was
            // dispatched in Plan mode and is still being read in it, and
            // never over a queued message, which the user has already
            // decided comes next.
            if (event["reason"] as? String ?? "complete") == "complete",
               turnDispatchedInPlanMode,
               selectedMode == .plan,
               planTodosChangedThisTurn,
               !todos.isEmpty,
               queuedMessages.isEmpty {
                planApprovalPending = true
            }
            planTodosChangedThisTurn = false
            turnDispatchedInPlanMode = false
            notifyTurnCompleteIfInactive()
            if persistenceEnabled {
                Task { await refreshMetadata() }
            }
            // Before the queue drains: a model chosen mid-turn is meant for
            // the messages waiting behind it.
            applyPendingProviderSwitchIfNeeded()
            Task { @MainActor [weak self] in
                self?.drainQueuedMessages()
            }

        case "error":
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            isBusy = false
            pendingRetry = false
            planApprovalPending = false
            planTodosChangedThisTurn = false
            turnDispatchedInPlanMode = false
            pendingSessionReset = false
            pendingCheckpointRestore = nil
            pendingRewindDraft = nil
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            blocks.append(
                ChatBlock(
                    kind: .error,
                    text: annotatingRejectedKey(event["message"] as? String ?? "Unknown agent error")
                )
            )
            // A turn that failed still ended. Held switches must drain here
            // too: one of them may be a revoked key the agent is still
            // holding, and dropping it keeps that credential in use.
            applyPendingProviderSwitchIfNeeded()

        case "slash_result":
            isBusy = false
            applyPendingProviderSwitchIfNeeded()
            if event["command"] as? String == "clear" {
                blocks = []
                todos = []
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
            planApprovalPending = false
            planTodosChangedThisTurn = false
            pendingRetry = false
            isBusy = true
        } else if pendingSessionReset || reason == "clear_chat" {
            flushPendingTokens()
            blocks = []
            todos = []
            planApprovalPending = false
            queuedMessages = []
            streamingAssistantID = nil
            restoredTranscriptContext = nil
            pendingSessionReset = false
            isBusy = false
            showToast("Fresh chat started")
        }
        if persistenceEnabled {
            Task { await refreshMetadata() }
        }
    }

    private func startAssistantStream() {
        flushPendingTokens()
        let id = UUID()
        streamingAssistantID = id
        isBusy = true
        blocks.append(ChatBlock(id: id, kind: .assistant, isStreaming: true))
    }

    /// No assistant bubble may stay in the streaming state once the turn is
    /// over — a missed message_end otherwise leaves a blinking cursor forever.
    private func finalizeStreamingBlocks() {
        for index in blocks.indices where blocks[index].isStreaming {
            blocks[index].isStreaming = false
        }
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
        isBusy = false
        pendingRetry = false
        // A pending "implement this plan?" survives the blip on purpose: the
        // decision is client-side state, and answering "implement" while
        // still disconnected is caught by resolvePlanApproval's guard.
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = false
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
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            self?.flushPendingTokens()
        }
    }

    private func flushPendingTokens() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !pendingTokens.isEmpty,
              let id = streamingAssistantID,
              let index = blocks.firstIndex(where: { $0.id == id })
        else {
            pendingTokens = ""
            return
        }
        blocks[index].text += pendingTokens
        streamedCharsThisTurn += pendingTokens.count
        pendingTokens = ""
        streamRevision += 1
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
        guard appliedWorkspacePath != info.cwd || pendingWorkspacePath == info.cwd else { return }
        let changedWorkspace = appliedWorkspacePath != nil && appliedWorkspacePath != info.cwd
        appliedWorkspacePath = info.cwd
        pendingWorkspacePath = nil
        if changedWorkspace {
            flushPendingTokens()
            blocks = []
            todos = []
            planApprovalPending = false
            restoredTranscriptContext = nil
        }
        if let profile = workspaceProfiles.first(where: { $0.path == info.cwd }) {
            draftText = profile.draft
            selectedMode = profile.mode
            settings.previewURL = profile.previewURL
            contextFiles = profile.contextFiles
            applyProfileRoute(profile, currentModel: info.model)
            Task { await refreshContextFiles() }
        }
        touchWorkspaceProfile(info.cwd)
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
        if let index = workspaceProfiles.firstIndex(where: { $0.path == path }) {
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
        workspaceProfiles = Array(workspaceProfiles.sorted { $0.lastOpened > $1.lastOpened }.prefix(8))
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
        // home directory — which must never be recorded as a recent
        // workspace, where it evicts real entries from the 8-slot list.
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
        if let index = workspaceProfiles.firstIndex(where: { $0.path == path }) {
            workspaceProfiles[index] = profile
        } else {
            workspaceProfiles.append(profile)
        }
        workspaceProfiles = Array(workspaceProfiles.sorted { $0.lastOpened > $1.lastOpened }.prefix(8))
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
            case .note: "Note: \(block.text)"
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
        connectionPhase = .connected
        ollamaOnline = true
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
                pinned: true
            ),
            SessionSummary(
                id: "seed-archived",
                name: "seed-archived.jsonl",
                preview: "Archived design pass",
                mtime: Date().addingTimeInterval(-600).timeIntervalSince1970,
                size: 300,
                archived: true
            ),
        ]
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

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
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
            case "assistant" where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                ChatBlock(kind: .assistant, text: message.content)
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
        case .askMode: "Switch to Ask mode"
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
        case .askMode: "questionmark.circle"
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
        case .planMode: "⌥P"
        case .buildMode: "⌥B"
        case .showShortcuts: "⌘/"
        case .chooseWorkspace, .newWorkspace, .browseModels, .refreshModels,
             .exportSession, .permissions, .openSettings: ""
        }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
