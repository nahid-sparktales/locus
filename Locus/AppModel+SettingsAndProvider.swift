import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Settings application (the change-diff engine over AppSettings),
/// appearance preview, terminal and iteration-limit sync, and building and
/// applying the provider route.
extension AppModel {
    func openWorkspaceInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspacePath)])
    }

    func openBackendFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settings.backendRoot))
    }

    /// Routes every workspace entry point through one presentation action so
    /// the destination is selected before SwiftUI evaluates the sheet.
    func presentSettings(_ page: SettingsPage? = nil) {
        if let page { settingsPage = page }
        settingsPresented = true
    }

    /// Persists settings without owning the Settings window lifecycle. Live
    /// controls and staged page applies both use this path while the window
    /// remains open; callers dismiss explicitly when the user chooses Close.
    func applySettings(
        _ newSettings: AppSettings,
        proxyCredentialChanged: Bool = false,
        showConfirmation: Bool = true
    ) {
        var newSettings = newSettings
        newSettings.maximumActiveChats = AppSettings.clampMaximumActiveChats(
            newSettings.maximumActiveChats
        )
        newSettings.worktreeRetentionLimit = AppSettings.clampWorktreeRetentionLimit(
            newSettings.worktreeRetentionLimit
        )
        newSettings.otlpSamplingRate = AppSettings.clampOTLPSamplingRate(
            newSettings.otlpSamplingRate
        )
        // Permissions are live controls, not part of the editable settings
        // draft. Preserve a choice made while this sheet was open.
        newSettings.permissionModeRaw = settings.permissionModeRaw
        // Local-model visibility is also managed immediately. A later Save on
        // General or Browser must not resurrect a model hidden moments ago.
        newSettings.hiddenLocalModels = settings.hiddenLocalModels
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
        let browserEnabledChanged = settings.browserEnabled != newSettings.browserEnabled
        let walletRPCChanged = settings.walletSepoliaRPCURL != newSettings.walletSepoliaRPCURL
        let walletFeatureAccessChanged = settings.walletAlphaEnabled
            != newSettings.walletAlphaEnabled
            || settings.walletBrowserProviderEnabled
                != newSettings.walletBrowserProviderEnabled
        let browserHistoryAccessChanged = settings.browserHistoryAccessRaw
            != newSettings.browserHistoryAccessRaw
        let browserAutofillAccessChanged = settings.browserAgentPasswordsEnabled
            != newSettings.browserAgentPasswordsEnabled
            || settings.browserAgentContactsEnabled != newSettings.browserAgentContactsEnabled
            || settings.browserAgentPaymentCardsEnabled
                != newSettings.browserAgentPaymentCardsEnabled
        let browserProfileChanged = settings.browserPersistProfile
            != newSettings.browserPersistProfile
        let voiceConfigurationChanged = settings.voiceSpeechEngineRaw
            != newSettings.voiceSpeechEngineRaw
            || settings.voiceCloudAccountID != newSettings.voiceCloudAccountID
            || settings.voiceLanguageIdentifier != newSettings.voiceLanguageIdentifier
            || settings.voiceSystemVoiceIdentifier != newSettings.voiceSystemVoiceIdentifier
            || settings.voiceAppleNetworkRecognitionAllowed
                != newSettings.voiceAppleNetworkRecognitionAllowed
            || settings.voiceCloudTranscriptionModel
                != newSettings.voiceCloudTranscriptionModel
            || settings.voiceCloudSpeechModel != newSettings.voiceCloudSpeechModel
            || settings.voiceCloudVoiceIdentifier != newSettings.voiceCloudVoiceIdentifier
        let proxyChanged = proxyCredentialChanged
            || settings.proxyModeRaw != newSettings.proxyModeRaw
            || settings.proxyTypeRaw != newSettings.proxyTypeRaw
            || settings.proxyHost != newSettings.proxyHost
            || settings.proxyPort != newSettings.proxyPort
            || settings.proxyBypass != newSettings.proxyBypass
            || settings.proxyUsername != newSettings.proxyUsername
            || settings.proxyProfiles != newSettings.proxyProfiles
            || settings.proxyActiveProfileID != newSettings.proxyActiveProfileID
            || settings.proxyStrictModeEnabled != newSettings.proxyStrictModeEnabled
            || settings.proxyAutoFailoverEnabled != newSettings.proxyAutoFailoverEnabled
            || settings.proxyScopeProfileIDs != newSettings.proxyScopeProfileIDs
            || settings.proxyWorkspaceProfileIDs != newSettings.proxyWorkspaceProfileIDs
            || settings.proxyProviderProfileIDs != newSettings.proxyProviderProfileIDs
        let launchAtLoginChanged = settings.launchAtLogin != newSettings.launchAtLogin
        let mobileAccessChanged = settings.mobileAccessEnabled != newSettings.mobileAccessEnabled
        if launchAtLoginChanged {
            do {
                try updateLaunchAtLogin(enabled: newSettings.launchAtLogin)
                launchAtLoginError = nil
            } catch {
                newSettings.launchAtLogin = settings.launchAtLogin
                launchAtLoginError = error.localizedDescription
            }
        }
        LocusAccentRuntime.shared.configure(newSettings.resolvedAccent)
        settings = newSettings
        if voiceConfigurationChanged {
            voiceControl.invalidateCapabilityTest()
        }
        if !newSettings.voiceControlsEnabled {
            voiceControl.exitVoiceMode()
        }
        appearancePreview = nil
        persistSettings()
        if mobileAccessChanged {
            Task { await companionGateway.setEnabled(newSettings.mobileAccessEnabled) }
        }
        browser.defaultViewport = newSettings.resolvedBrowserViewport.size
        applyBrowserSettings(newSettings)
        if walletRPCChanged {
            walletGateway.configureRPCURL(newSettings.walletSepoliaRPCURL)
        }
        if walletFeatureAccessChanged {
            walletGateway.applyFeatureAccess(
                walletEnabled: newSettings.walletAlphaEnabled,
                browserEnabled: newSettings.walletBrowserProviderEnabled
            )
            browser.applyWalletProviderAccess(reloadTabs: true)
            refreshWalletCapabilities()
        }

        if browserEnabledChanged || browserHistoryAccessChanged || browserAutofillAccessChanged {
            announceBrowserCapability()
            if !newSettings.browserEnabled { browser.cancelPendingActions() }
        }
        if browserProfileChanged { syncBrowserProfile() }

        if providerChanged, !proxyChanged {
            ProxyRuntime.shared.noteRoutingContext(
                workspacePath: workspacePath,
                providerAccountID: newSettings.activeAccountID
            )
        }

        if proxyChanged {
            // Before any restart, so the relaunched agent and every rebuilt
            // session see the new configuration, not the one being replaced.
            ProxyRuntime.shared.update(
                settings: newSettings,
                password: persistenceEnabled ? CredentialStore.proxyPassword() : nil,
                profilePasswords: persistenceEnabled
                    ? CredentialStore.proxyPasswords(for: newSettings.allProxyProfiles) : [:],
                workspacePath: workspacePath,
                providerAccountID: newSettings.activeAccountID
            )
            if persistenceEnabled {
                CredentialStore.removeOrphanedProxyProfilePasswords(
                    keeping: Set(newSettings.allProxyProfiles.map(\.id))
                )
            }
            scheduleProxyHealthMonitoring()
            let hasActiveWorker = taskWorkers.values.contains {
                $0.occupiesExecutionSlot || $0.startedAt != nil
            }
            if hasActiveWorker || isBusy {
                proxyRouteRestartPending = true
            } else {
                taskWorkers.values.forEach { $0.stop() }
                taskWorkers.removeAll()
                syncBrowserProtectedSessions()
            }
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
        if showConfirmation {
            if let launchAtLoginError {
                showToast("Settings saved, but launch at login could not change: \(launchAtLoginError)")
            } else {
                showToast("Settings saved")
            }
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered { try service.register() }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    /// Preview never mutates `settings`, so Cancel can restore the committed
    /// appearance without triggering persistence or backend side effects.
    func previewAppearance(_ rawValue: String) {
        appearancePreview = AppAppearance(rawValue: rawValue) ?? .system
    }

    func clearAppearancePreview() {
        appearancePreview = nil
    }

    func migrateTerminalSettingsIfNeeded() async {
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
                "codex_home_id": account.codexHomeIdentifier,
                "account_label": account.displayName,
                "model": account.preferredModel,
                // Always sent: the backend keeps its current value for any
                // missing field, so omitting one would freeze a stale choice.
                "native_mode": account.codexNativeModeEnabled,
                "web_search": account.codexWebSearchEnabled,
                // The workspace's own choice when it has one, else the
                // account's default — the header picker overrides the editor.
                "reasoning_effort": effortToSend(for: account),
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
            // Always sent, like the ChatGPT route's copy: "" is a real choice
            // meaning the model's default, and omitting the key would leave a
            // cleared effort reading as "keep whatever was set before".
            "reasoning_effort": effortToSend(for: account),
            "verify": verify,
        ]
    }

    /// The effort to actually request, or "" when this model will not take the
    /// one that is stored.
    ///
    /// The stored choice belongs to the workspace, not to the account, so it
    /// outlives a switch between them: "max" set on a Claude model is still
    /// there when the same workspace routes to a ChatGPT plan, which tops out
    /// at "xhigh". An effort a model does not accept fails the turn rather than
    /// being ignored, so it is filtered here rather than sent hopefully.
    private func effortToSend(for account: ProviderAccount) -> String {
        let effort = resolvedReasoningEffort
        guard !effort.isEmpty else { return "" }
        let model = routedModel(for: account)
        guard account.kind == .chatGPT else {
            return account.kind.publishedReasoningEfforts(for: model)
                .contains(effort) ? effort : ""
        }
        // The catalog arrives asynchronously, and a backend older than
        // effort reporting sends no efforts at all. With nothing to check
        // against, the helper is the authority — pass the choice through
        // rather than silently dropping what the user asked for.
        guard let supported = accountModelCatalogs[account.id]?
            .first(where: { $0.id == model })?
            .supportedReasoningEfforts
        else { return effort }
        return supported.contains { $0.effort == effort } ? effort : ""
    }

    /// Pushes the chosen provider to the local agent. The key travels from the
    /// app's credential file to the agent process in memory — the agent never
    /// writes it to its own config, so it is re-sent on every launch.
    @discardableResult
    func applyProvider(verify: Bool = false, announce: Bool = true) async -> Bool {
        let account = activeAccount
        if let account, account.kind != .chatGPT, account.resolvedBaseURL.isEmpty {
            if announce {
                showToast("Add the endpoint URL for \(account.displayName) in Settings")
            }
            return true
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
            guard announce else { return true }
            showToast(
                state.provider == "remote" || state.provider == "chatgpt"
                    ? "Using \(account?.displayName ?? shortHost(state.host))"
                    : "Using local Ollama"
            )
            return true
        } catch {
            let message = "Could not restore the model provider: \(error.localizedDescription)"
            modelRuntimePhase = .unavailable(message)
            if let account {
                accountStatus[account.id] = .failed(message)
            }
            if announce {
                showToast("Could not switch model provider: \(error.localizedDescription)")
            }
            return false
        }
    }

    /// A successful Settings probe proves the provider accepted the tested
    /// credential, but that request bypasses the local agent. Reapply the
    /// active saved account so a helper that just restarted receives its key
    /// again. A newly typed key remains a draft and must be saved first.
    func reconnectAfterSuccessfulConnectionTest(
        account: ProviderAccount,
        usedSavedCredential: Bool
    ) async -> ProviderConnectionTestFollowUp {
        guard activeAccount?.id == account.id else { return .notNeeded }
        guard usedSavedCredential else { return .saveRequired }
        guard await applyProvider(announce: false) else { return .reconnectFailed }
        if accountStatus[account.id]?.isHealthy != true {
            accountStatus[account.id] = .keySaved
        }
        return .reconnected
    }

    func shortHost(_ value: String) -> String {
        guard let host = URL(string: value)?.host else { return value }
        return host
    }
}
