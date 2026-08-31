import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Permission mode changes and resets, native tool-request routing
/// (simulator, browser, notes, wallet, computer control), and capability
/// announcements to every live transport.
extension AppModel {
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

    func syncPreferredPermissionMode(to transport: BackendService) {
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

    /// Run one simulator action and answer on the socket that asked for it.
    /// Simulator HID is device-scoped and does not move the Mac pointer, so a
    /// background task may continue on its own leased UDID without taking over
    /// the foreground conversation.
    @discardableResult
    func runSimulatorAction(
        _ event: [String: Any],
        workspacePath requestedWorkspacePath: String? = nil,
        reply: @escaping @MainActor ([String: Any]) -> Void
    ) -> Task<Void, Never>? {
        guard let requestID = event["request_id"] as? String,
              let tool = event["tool"] as? String,
              let arguments = event["arguments"] as? [String: Any]
        else { return nil }
        let sessionID = (event["session_id"] as? String) ?? currentSessionID
        let ownerWorkspace = requestedWorkspacePath ?? workspacePath
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingSimulatorActions.removeValue(forKey: requestID) }
            if sessionID == self.currentSessionID {
                self.selectInspectorTab(.simulator)
            }
            let result = await self.simulatorControl.perform(
                tool: tool,
                arguments: arguments,
                sessionID: sessionID,
                workspacePath: ownerWorkspace,
                hostedProvider: self.activeAccount?.displayName,
                timeoutMilliseconds: event["timeout_ms"] as? Int ?? 120_000
            )
            reply([
                "type": "simulator_action_result",
                "request_id": requestID,
                "result": result,
            ])
            if tool == "simulator_detach" {
                self.objectWillChange.send()
                self.announceSimulatorControlCapability()
            }
        }
        pendingSimulatorActions[requestID] = (sessionID, task)
        return task
    }

    func cancelSimulatorActions(sessionID: String? = nil) {
        let requestIDs = pendingSimulatorActions.compactMap { requestID, pending in
            sessionID == nil || pending.sessionID == sessionID ? requestID : nil
        }
        for requestID in requestIDs {
            pendingSimulatorActions.removeValue(forKey: requestID)?.task.cancel()
        }
        simulatorControl.cancelPendingActions(sessionID: sessionID)
    }

    func runSimulatorAction(
        _ event: [String: Any],
        workspacePath: String,
        on transport: BackendService
    ) {
        runSimulatorAction(event, workspacePath: workspacePath) { payload in
            _ = transport.send(payload)
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
            // Chat workers keep running without pulling the current chat away.
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

    func runBrowserAction(_ event: [String: Any], on transport: BackendService) {
        runBrowserAction(event) { payload in
            _ = transport.send(payload)
        }
    }

    /// Read or update the notes document owned by the requesting chat.
    ///
    /// Like Browser, requests from background workers are answered on their
    /// own transport and never switch the foreground conversation. Unlike
    /// Browser, callers cannot supply a path: the runtime that owns the socket
    /// supplies the workspace and the app-wide setting supplies the scope.
    @discardableResult
    func runNotesAction(
        _ event: [String: Any],
        workspacePath requestedWorkspacePath: String? = nil,
        reply: @escaping @MainActor ([String: Any]) -> Void
    ) -> Task<Void, Never>? {
        guard let requestID = event["request_id"] as? String,
              let tool = event["tool"] as? String,
              let arguments = event["arguments"] as? [String: Any]
        else { return nil }
        let sessionID = (event["session_id"] as? String) ?? currentSessionID
        let ownerWorkspace = requestedWorkspacePath ?? workspacePath
        return Task { @MainActor [weak self] in
            guard let self else { return }
            if sessionID == self.currentSessionID {
                self.selectInspectorTab(.notes)
            }
            let store = NotesStore.shared(
                workspacePath: ownerWorkspace,
                sessionID: sessionID,
                scope: self.settings.resolvedNotesScope
            )
            reply([
                "type": "notes_action_result",
                "request_id": requestID,
                "result": store.perform(tool: tool, arguments: arguments),
            ])
        }
    }

    func runNotesAction(
        _ event: [String: Any],
        workspacePath: String,
        on transport: BackendService
    ) {
        runNotesAction(event, workspacePath: workspacePath) { payload in
            _ = transport.send(payload)
        }
    }

    /// Wallet requests never receive secret material. The native gateway
    /// returns only public account data, prepared-intent summaries, or a
    /// transaction result after the signer and session policy have approved it.
    @discardableResult
    func runWalletAction(
        _ event: [String: Any],
        reply: @escaping @MainActor ([String: Any]) -> Void
    ) -> Task<Void, Never>? {
        guard let requestID = event["request_id"] as? String,
              let tool = event["tool"] as? String,
              let arguments = event["arguments"] as? [String: Any]
        else { return nil }
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.walletGateway.perform(tool: tool, arguments: arguments)
            if self.walletGateway.pendingConfirmation != nil {
                self.presentSettings(.wallet)
            }
            reply([
                "type": "wallet_action_result",
                "request_id": requestID,
                "result": result,
            ])
        }
    }

    func runWalletAction(_ event: [String: Any], on transport: BackendService) {
        runWalletAction(event) { payload in
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
        announceComputerControlCapability()
        showToast(enabled ? "Computer Control enabled" : "Computer Control disabled")
    }

    func sendComputerControlCapability() {
        sendComputerControlCapability(to: conversationBackend, sessionID: currentSessionID)
    }

    func announceComputerControlCapability() {
        sendComputerControlCapability(to: backend, sessionID: currentSessionID)
        for runtime in taskWorkers.values {
            sendComputerControlCapability(to: runtime.service, sessionID: runtime.sessionID)
        }
    }

    func sendComputerControlCapability(
        to transport: BackendService,
        sessionID: String? = nil
    ) {
        let owner = sessionID ?? currentSessionID
        let scope = liveApplicationTargets[owner]
        let scopedApplicationConnected = scope.map(applicationContext.isConnected) ?? false
        var payload: [String: Any] = [
            "type": "set_computer_control",
            "enabled": Self.effectiveComputerControlEnabled(
                globalEnabled: settings.computerControlEnabled,
                hasLiveApplication: scope != nil,
                liveApplicationConnected: scopedApplicationConnected
            ),
            "native_available": ComputerControlService.isAvailable,
            "scope": scope == nil ? "all" : "application",
        ]
        if let scope { payload["application"] = scope.scopePayload }
        _ = transport.send(payload)
    }

    static func effectiveComputerControlEnabled(
        globalEnabled: Bool,
        hasLiveApplication: Bool,
        liveApplicationConnected: Bool
    ) -> Bool {
        hasLiveApplication ? liveApplicationConnected : globalEnabled
    }

    func sendSimulatorControlCapability() {
        sendSimulatorControlCapability(to: conversationBackend, sessionID: currentSessionID)
    }

    func announceSimulatorControlCapability() {
        sendSimulatorControlCapability(to: backend, sessionID: currentSessionID)
        for runtime in taskWorkers.values {
            sendSimulatorControlCapability(to: runtime.service, sessionID: runtime.sessionID)
        }
    }

    func sendSimulatorControlCapability(
        to transport: BackendService,
        sessionID: String? = nil
    ) {
        let owner = sessionID ?? currentSessionID
        let target = simulatorControl.target(for: owner)
        let enabled = settings.simulatorControlEnabled
            && target != nil
            && simulatorControl.nativeAvailable
        var payload: [String: Any] = [
            "type": "set_simulator_control",
            "enabled": enabled,
            "native_available": simulatorControl.nativeAvailable,
        ]
        if let target {
            payload["attached_device"] = [
                "udid": target.udid,
                "name": target.device.name,
                "runtime": target.device.runtime,
                "family": target.device.family,
                "state": target.device.state.rawValue,
            ]
        }
        _ = transport.send(payload)
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
    func announceBrowserCapability() {
        sendBrowserCapability(to: backend)
        for runtime in taskWorkers.values {
            sendBrowserCapability(to: runtime.service)
        }
    }

    func sendBrowserCapability(to transport: BackendService) {
        let delivered = transport.send(browserCapabilityPayload)
        // The agent refuses capability changes mid-turn and Swift historically
        // dropped the answer, so a toggle during a long turn was lost until the
        // next reconnect. Retry once the turn is over instead.
        if !delivered || isBusy {
            pendingBrowserCapabilityTransports.append(transport)
        }
    }

    private var browserCapabilityPayload: [String: Any] {
        [
            "type": "set_browser_control",
            "enabled": settings.browserEnabled,
            "history_enabled": settings.resolvedBrowserHistoryAccess != .disabled,
            "autofill_categories": settings.browserAgentAutofillCategories
                .map(\.rawValue).sorted(),
        ]
    }

    /// Notes are a native app surface, so headless agents should not advertise
    /// its tools. Every live Locus transport gets this handshake once it is
    /// connected; the actual workspace and scope stay enforced in Swift.
    func sendNotesCapability(to transport: BackendService) {
        _ = transport.send([
            "type": "set_notes_control",
            "enabled": true,
        ])
    }

    /// The backend only learns about wallet tools when an explicitly enabled,
    /// security-reviewed native signer is available. A release without that
    /// signer has no advertised wallet surface to guess or call.
    func sendWalletCapability(to transport: BackendService) {
        _ = transport.send([
            "type": "set_wallet_control",
            "capability": (walletGateway.capability as Any?) ?? NSNull(),
        ])
    }

    func refreshWalletCapabilities() {
        sendWalletCapability(to: backend)
        for runtime in taskWorkers.values {
            sendWalletCapability(to: runtime.service)
        }
    }

    /// Re-announce anything the agent refused while it was busy.
    func flushPendingBrowserCapability() {
        guard !pendingBrowserCapabilityTransports.isEmpty else { return }
        let transports = pendingBrowserCapabilityTransports
        pendingBrowserCapabilityTransports.removeAll()
        for transport in transports {
            if !transport.send(browserCapabilityPayload) {
                pendingBrowserCapabilityTransports.append(transport)
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
        case .grillMode: selectedMode = .grill
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
        case .showNotebook: notebookPresented = true
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
}
