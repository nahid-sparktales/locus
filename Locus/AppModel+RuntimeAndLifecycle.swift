import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// App startup and supervision: bootstrap, unclean-exit recovery, backend
/// and Ollama runtime recovery with its health monitor, proxy health and
/// route restarts, shutdown, notifications, and the periodic metadata
/// refresh.
extension AppModel {
    func bootstrap() async {
        let recovery = scheduleRuntimeRecovery(
            reason: "Starting the local services…",
            immediate: true
        )
        await recovery?.value
        await restoreAfterUncleanExitIfNeeded()
        await activity.refreshActivityRuns(announceFailure: false)
        restorePersistedQueuedRuns()
        await schedule.refreshScheduledTasks(announceFailure: false)
        await schedule.processDueSchedules()
        schedule.startScheduleCoordinator()
        eventAutomations.start()
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
    func scheduleRuntimeRecovery(
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
                environmentOverlay: ProxyRuntime.shared.environmentOverlay(
                    scope: .modelAndAgent,
                    workspacePath: workspacePath,
                    providerAccountID: settings.activeAccountID
                ),
                proxyCredential: ProxyRuntime.shared.childCredential(
                    scope: .modelAndAgent,
                    workspacePath: workspacePath,
                    providerAccountID: settings.activeAccountID
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

        // The app is the source of truth for provider routing and credentials,
        // so it must reapply them after every agent restart. A live HTTP server
        // is not a recovered runtime until that handoff succeeds: hosted keys
        // live only in the app's credential file and process memory, never in
        // the agent config it just reloaded.
        guard await applyProvider(announce: false) else {
            agentRuntimePhase = .recovering("Restoring the model provider…")
            return false
        }
        agentRuntimePhase = .online
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

    func ensureLocalOllama(at hostValue: String) async {
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

    func refreshProxyHealth() {
        guard !isCheckingProxyHealth else { return }
        Task { @MainActor [weak self] in
            await self?.performProxyHealthCheck()
        }
    }

    private func performProxyHealthCheck() async {
        guard settings.resolvedProxyMode == .manual else {
            proxyHealthRecords = []
            proxyHealthMessage = "Choose Manual proxy mode to check profiles."
            return
        }
        guard !isCheckingProxyHealth else { return }
        isCheckingProxyHealth = true
        proxyHealthMessage = "Checking every enabled proxy…"
        let result = await ProxyRuntime.shared.refreshHealth()
        proxyHealthRecords = result.records
        let healthy = result.records.filter(\.ok).count
        if result.records.isEmpty {
            proxyHealthMessage = "No enabled, complete proxy profiles are available."
        } else if healthy == result.records.count {
            proxyHealthMessage = "All (healthy) proxy profile\(healthy == 1 ? " is" : "s are") healthy."
        } else {
            proxyHealthMessage = "(healthy) of (result.records.count) proxy profiles are healthy."
        }
        isCheckingProxyHealth = false
        if result.routingChanged { requestProxyRouteRestart() }
    }

    func scheduleProxyHealthMonitoring() {
        proxyHealthMonitorTask?.cancel()
        proxyHealthMonitorTask = nil
        proxyHealthRecords = ProxyRuntime.shared.healthSnapshot
        guard persistenceEnabled,
              settings.resolvedProxyMode == .manual,
              settings.proxyAutoFailoverEnabled
        else { return }
        proxyHealthMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.isShuttingDown {
                await self.performProxyHealthCheck()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    /// URL sessions move immediately because they are rebuilt from the proxy
    /// generation. Local agent services inherit proxy variables at launch, so
    /// an idle service is relaunched; active work is allowed to finish first.
    private func requestProxyRouteRestart() {
        let hasActiveWorker = taskWorkers.values.contains {
            $0.occupiesExecutionSlot || $0.startedAt != nil
        }
        guard !isBusy, !hasActiveWorker, pendingChatTurns.isEmpty else {
            proxyRouteRestartPending = true
            if !proxyHealthMessage.contains("active agent") {
                proxyHealthMessage += " The active agent will switch routes after its work finishes."
            }
            return
        }
        proxyRouteRestartPending = false
        taskWorkers.values.forEach { $0.stop() }
        taskWorkers.removeAll()
        syncBrowserProtectedSessions()
        backend.disconnect()
        Task { [backendProcess] in
            await backendProcess.stopAndWait()
            await self.bootstrap()
        }
    }

    func applyPendingProxyRouteRestartIfPossible() {
        guard proxyRouteRestartPending else { return }
        requestProxyRouteRestart()
    }

    func shutdown() {
        isShuttingDown = true
        Task { await companionGateway.setEnabled(false) }
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
        proxyHealthMonitorTask?.cancel()
        streamFlushDriver.invalidate()
        profilePersistenceTask?.cancel()
        settingsPersistenceTask?.cancel()
        sessionResetWatchdog?.cancel()
        workspaceFiles.stop()
        knowledge.cancelAll()
        agentInstructions.cancelAll()
        runs.cancelAll()
        schedule.cancelAll()
        eventAutomations.stop()
        backend.disconnect()
        backendProcess.stop()
        taskWorkers.values.forEach { $0.stop() }
        taskWorkers.removeAll()
        ollamaRuntime.stopOwnedCLI()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        privacyLockObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        privacyLockObservers.removeAll()
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

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        guard persistenceEnabled,
              settings.notifyOnCompletion || settings.notifyOnNeedsAttention else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyTurnCompleteIfInactive(
        sessionID: String? = nil,
        runID: String? = nil,
        workspace: String? = nil
    ) {
        let resolvedWorkspace = workspace ?? workspacePath
        deliverNotification(
            body: "Finished responding in \(URL(fileURLWithPath: resolvedWorkspace).lastPathComponent).",
            enabled: settings.notifyOnCompletion,
            sessionID: sessionID,
            runID: runID
        )
    }

    func notifyNeedsAttentionIfInactive(
        body: String = "Locus needs permission to continue.",
        sessionID: String? = nil,
        runID: String? = nil
    ) {
        deliverNotification(
            body: body,
            enabled: settings.notifyOnNeedsAttention,
            sessionID: sessionID,
            runID: runID
        )
    }

    private func deliverNotification(
        body: String,
        enabled: Bool,
        sessionID: String? = nil,
        runID: String? = nil
    ) {
        guard persistenceEnabled, enabled, !NSApp.isActive else { return }
        let resolvedSessionID = sessionID ?? currentSessionID
        let resolvedRunID = runID
            ?? orchestrationRunID
            ?? taskConversationStates[resolvedSessionID]?.runID
            ?? ""
        let content = UNMutableNotificationContent()
        content.title = "Locus"
        content.body = body
        content.sound = .default
        content.userInfo = [
            "session_id": resolvedSessionID,
            "run_id": resolvedRunID,
        ]
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
            // `/api/models` describes the active provider. Only trust it as the
            // local list when local is what is active.
            if activeAccount == nil {
                installedLocalModels = response.models
                localModels = providerAccountsModel.visibleLocalModels(in: response.models)
                models = localModels
            } else {
                models = response.models
            }
        } catch {
            // Connection state communicates backend failures.
        }
        if activeAccount != nil { await providerAccountsModel.refreshLocalModels() }
        await providerAccountsModel.refreshAccountCatalogs()
        await migrateTerminalSettingsIfNeeded()

        do {
            let suffix = showArchivedSessions
                ? "?include_archived=true&limit=500"
                : "?limit=500"
            let response = try await backend.get("/api/sessions\(suffix)", as: SessionsResponse.self)
            sessions = response.sessions
            if let folders = try? await backend.get(
                "/api/chat-folders", as: ChatFoldersResponse.self
            ) {
                chatFolders = folders.folders
            }
            if taskWorkers[currentSessionID] == nil {
                currentSessionID = response.current
            }
            reconcileChatSplitRestoration()
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

        await extensionsModel.refreshExtensions()
        gitWorkspace.refreshBranch()
    }
}
