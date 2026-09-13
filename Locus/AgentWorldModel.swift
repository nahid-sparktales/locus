import AppKit
import Combine
import Foundation
import SwiftUI

enum AgentWorldError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

struct AgentWorldResident: Identifiable, Equatable, Encodable {
    let id: String
    let name: String
    let role: String
    let status: String
    var detail: String?
}

struct AgentWorldConversationState {
    var status = "idle"
    var detail: String?
    var busy = false
    var blocks: [ChatBlock] = []
}

/// Window, roster and conversation bindings belong to this feature. Only the
/// native conversation panel has execution authority; plugin JavaScript sees
/// names, roles and activity labels, never transcripts or provider material.
@MainActor
final class AgentWorldModel: NSObject, ObservableObject, NSWindowDelegate {
    weak var appModel: AppModel?
    @Published var conversationPresented = false
    @Published var sharedChatPresented = false
    @Published private(set) var activatingConversation = false
    @Published var selectedTransfer: AgentWorldTransfer?
    @Published var newAgentDraft: AgentProfile?
    @Published private(set) var attentionRequests: [AgentWorldAttention] = []
    @Published private(set) var transfers: [AgentWorldTransfer] = []
    @Published private(set) var residents: [AgentWorldResident] = []
    @Published private(set) var availableScreens: [AvailableScreen] = []
    @Published private(set) var selection: String?
    @Published private(set) var activeScreen: AvailableScreen?
    @Published private(set) var workspace = ""
    @Published private(set) var blocks: [ChatBlock] = []
    @Published private(set) var conversationBusy = false
    @Published private(set) var pendingCount = 0
    @Published var draft = ""
    @Published var error: String?
    @Published private(set) var theme = "outpost"
    @Published private(set) var residentStyle = "mixed"
    @Published var graphicsError: String?
    var projectName: String { URL(fileURLWithPath: workspace).lastPathComponent }
    var selectedProfile: AgentProfile? { profilesProvider().first { $0.id.uuidString == selection } }
    var selectedSessionID: String? { selectedSessionOverride ?? selection.flatMap { bindings[Self.bindingKey(workspace: workspace, profileID: $0)] } }
    var canInteract: Bool { activeScreen?.screen.capabilities.contains("agents.interact") == true }
    var canCreateAgent: Bool { canInteract && appModel != nil && !isVisualFixture }

    struct AvailableScreen: Identifiable, Equatable {
        let pluginID: String
        let pluginName: String
        let digest: String?
        let root: String
        let screen: ExtensionPluginScreen
        var id: String { pluginID + ":" + screen.id }
    }
    private struct QueuedTurn {
        let text: String
        let mode: WorkMode
    }
    private var profilesProvider: () -> [AgentProfile] = { [] }
    private var workspaceProvider: () -> String = { "" }
    private var availabilityProvider: (AgentProfile) -> String? = { _ in nil }
    private var stateProvider: (String) -> AgentWorldConversationState = { _ in .init() }
    private var createConversation: (String, AgentProfile) async throws -> String = { _, _ in throw AgentWorldError.unavailable("Connect the agent first.") }
    private var loadConversation: (String) async throws -> Void = { _ in }
    private var creationTasks: [String: Task<String, Error>] = [:]
    private var activityProvider: (AgentProfile, String) -> AgentWorldConversationState? = { _, _ in nil }
    private var dispatch: (String, String, UUID, String, WorkMode) async throws -> Void = { _, _, _, _, _ in }
    private var stopConversation: (String) -> Void = { _ in }
    private var openConversation: (String) -> Void = { _ in }
    private var manageProfiles: () -> Void = {}
    private var subscriptions = Set<AnyCancellable>()
    private var catalog = ExtensionsResponse.empty
    private var bindings: [String: String] = [:]
    /// The current resident conversation can be replaced without converting
    /// its saved history into an ordinary, unrestricted model-picker chat.
    private var profileHistory: [String: String] = [:]
    private var defaults: UserDefaults?
    private var window: NSWindow?
    private var refreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var activationToken = UUID()
    private var selectedSessionOverride: String?
    private var queues: [String: [QueuedTurn]] = [:]
    private var runners: [String: Task<Void, Never>] = [:]
    private var runnerTokens: [String: UUID] = [:]
    private var queueErrors: [String: String] = [:]
    private var windowWorkspace = ""
    private var isVisualFixture = false
    var visibilityChanged: ((Bool) -> Void)?

    func configure(
        extensions: ExtensionsModel,
        profiles: @escaping () -> [AgentProfile], workspace: @escaping () -> String,
        availability: @escaping (AgentProfile) -> String?,
        state: @escaping (String) -> AgentWorldConversationState,
        create: @escaping (String, AgentProfile) async throws -> String,
        load: @escaping (String) async throws -> Void,
        activity: @escaping (AgentProfile, String) -> AgentWorldConversationState? = { _, _ in nil },
        dispatch: @escaping (String, String, UUID, String, WorkMode) async throws -> Void,
        stop: @escaping (String) -> Void, open: @escaping (String) -> Void,
        manage: @escaping () -> Void, defaults: UserDefaults?
    ) {
        profilesProvider = profiles; workspaceProvider = workspace; availabilityProvider = availability
        stateProvider = state; createConversation = create; loadConversation = load; activityProvider = activity
        self.dispatch = dispatch; stopConversation = stop; openConversation = open
        manageProfiles = manage; self.defaults = defaults
        if let data = defaults?.data(forKey: "Locus.AgentWorld.conversations.v1"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) { bindings = saved }
        if let data = defaults?.data(forKey: "Locus.AgentWorld.profileHistory.v1"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            profileHistory = saved.filter { UUID(uuidString: $0.value) != nil }
        }
        // Migrate existing current bindings before any replacement can remove
        // their only native profile reference. Existing history is authoritative.
        for (key, sessionID) in bindings where profileHistory[sessionID] == nil {
            if let profileID = UUID(uuidString: String(key.split(separator: "\n").last ?? "")) {
                profileHistory[sessionID] = profileID.uuidString
            }
        }
        persistConversationBindings()
        subscriptions.removeAll()
        extensions.$extensions.sink { [weak self] value in
            self?.catalog = value
            self?.refresh()
        }.store(in: &subscriptions)
    }

    func boundProfileID(for sessionID: String) -> UUID? {
        profileHistory[sessionID].flatMap(UUID.init(uuidString:))
    }

    func hasPendingWork(profileID: UUID) -> Bool {
        let suffix = "\n" + profileID.uuidString.lowercased()
        return creationTasks.keys.contains { $0.hasSuffix(suffix) }
            || runners.keys.contains { $0.hasSuffix(suffix) }
            || queues.contains { $0.key.hasSuffix(suffix) && !$0.value.isEmpty }
    }

    func bindConversation(_ sessionID: String, workspace: String, profileID: UUID) {
        guard boundProfileID(for: sessionID).map({ $0 == profileID }) ?? true else { return }
        profileHistory[sessionID] = profileID.uuidString
        bindings[Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)] = sessionID
        persistConversationBindings()
        refresh()
    }

    private func persistConversationBindings() {
        // Persist identity before selection: an interrupted save must never
        // leave a known agent conversation without its profile restrictions.
        if let data = try? JSONEncoder().encode(profileHistory) { defaults?.set(data, forKey: "Locus.AgentWorld.profileHistory.v1") }
        if let data = try? JSONEncoder().encode(bindings) { defaults?.set(data, forKey: "Locus.AgentWorld.conversations.v1") }
    }

    static func bindingKey(workspace: String, profileID: String) -> String {
        SessionSummary.canonicalWorkspacePath(workspace) + "\n" + profileID.lowercased()
    }

    static func enabled(_ plugin: ExtensionPlugin, workspace: String) -> Bool {
        let canonical = SessionSummary.canonicalWorkspacePath(workspace)
        guard !plugin.disabledWorkspaces.contains(where: { SessionSummary.canonicalWorkspacePath($0) == canonical }) else { return false }
        return plugin.enabledGlobal || plugin.enabledWorkspaces.contains(where: { SessionSummary.canonicalWorkspacePath($0) == canonical })
    }

    func refresh() {
        let currentWorkspace = SessionSummary.canonicalWorkspacePath(workspaceProvider())
        let candidates: [AvailableScreen] = catalog.capabilities.pluginScreens == true
            ? catalog.plugins.filter { Self.enabled($0, workspace: currentWorkspace) && $0.error == nil }.flatMap { plugin in
                guard let root = plugin.root, root.hasPrefix("/") else { return [AvailableScreen]() }
                return (plugin.screens ?? []).filter(\.isSupported).map {
                    AvailableScreen(pluginID: plugin.id, pluginName: plugin.displayName ?? plugin.name,
                                    digest: plugin.digest, root: root, screen: $0)
                }
            } : []
        if availableScreens != candidates { availableScreens = candidates }
        if let activeScreen {
            let stillEnabled = catalog.plugins.first { $0.id == activeScreen.pluginID }.map {
                Self.enabled($0, workspace: windowWorkspace) && $0.error == nil && $0.root == activeScreen.root
                    && $0.digest == activeScreen.digest && ($0.screens ?? []).contains(activeScreen.screen)
            } ?? false
            if !stillEnabled || catalog.capabilities.pluginScreens != true {
                // Revoke access synchronously before WebKit is torn down.
                self.activeScreen = nil
                selectionTask?.cancel()
                for key in Array(queues.keys) where key.hasPrefix(windowWorkspace + "\n") { queues[key] = [] }
                window?.close()
                return
            }
        }
        let targetWorkspace = activeScreen == nil ? currentWorkspace : windowWorkspace
        if workspace != targetWorkspace { workspace = targetWorkspace }
        let updated = profilesProvider().map { profile -> AgentWorldResident in
            let key = Self.bindingKey(workspace: targetWorkspace, profileID: profile.id.uuidString)
            let conversation = bindings[key].map(stateProvider) ?? .init()
            let state = conversation.busy ? conversation : activityProvider(profile, targetWorkspace) ?? conversation
            let issue = availabilityProvider(profile)
            return AgentWorldResident(id: profile.id.uuidString, name: profile.name, role: profile.role.rawValue,
                                      status: issue != nil || (queueErrors[key] != nil && !state.busy) ? "failed" : state.status,
                                      detail: issue ?? queueErrors[key] ?? state.detail)
        }
        if residents != updated { residents = updated }
        if let appModel {
            if window?.occlusionState.contains(.visible) == true { appModel.refreshAgentWorldRunSignals(workspace: targetWorkspace) }
            let signals = appModel.agentWorldSignals(workspace: targetWorkspace)
            if attentionRequests != signals.attention { attentionRequests = signals.attention }
            if transfers != signals.transfers { transfers = signals.transfers }
        }
        if let selection, !profilesProvider().contains(where: { $0.id.uuidString == selection }) {
            self.selection = nil; blocks = []; error = "This agent profile was removed."
        }
        if let id = selectedSessionID {
            let state = stateProvider(id)
            if blocks != state.blocks { blocks = state.blocks }
            conversationBusy = state.busy
            let key = Self.bindingKey(workspace: targetWorkspace, profileID: selection ?? "")
            pendingCount = queues[key]?.count ?? 0
        } else {
            conversationBusy = false; pendingCount = 0
        }
    }

    func open(pluginID: String? = nil, screenID: String? = nil) {
        refresh()
        guard let choice = availableScreens.first(where: {
            (pluginID == nil || $0.pluginID == pluginID) && (screenID == nil || $0.screen.id == screenID)
        }) else { error = "Install and enable Agent World for this project in Extensions."; return }
        if window != nil, activeScreen == choice, windowWorkspace == SessionSummary.canonicalWorkspacePath(workspaceProvider()) {
            window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        window?.close()
        windowWorkspace = SessionSummary.canonicalWorkspacePath(workspaceProvider())
        workspace = windowWorkspace; activeScreen = choice; selection = nil; blocks = []; error = nil
        selectedSessionOverride = nil; conversationPresented = false; sharedChatPresented = false; selectedTransfer = nil
        theme = defaults?.string(forKey: "Locus.AgentWorld.theme.v1." + choice.id).flatMap { Self.isSafeThemeID($0) ? $0 : nil } ?? "outpost"
        residentStyle = defaults?.string(forKey: "Locus.AgentWorld.residentStyle.v1." + choice.id).flatMap { Self.isSafeResidentStyle($0) ? $0 : nil } ?? "mixed"
        graphicsError = nil; draft = ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(choice.screen.title) · \(projectName)"
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AgentWorldView(model: self))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        visibilityChanged?(false); visibilityChanged = nil
        refreshTask?.cancel(); refreshTask = nil; selectionTask?.cancel(); activationTask?.cancel()
        appModel?.agentWorldOwnsPresentations = false
        newAgentDraft = nil
        window?.contentView = nil; window = nil; activeScreen = nil
        // Runners and the application's workers intentionally outlive the window.
    }
    func windowDidBecomeKey(_ notification: Notification) { appModel?.agentWorldOwnsPresentations = true }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged?(false) }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged?(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged?(window?.occlusionState.contains(.visible) == true) }

    func select(_ agentID: String) {
        guard canInteract, let profile = profilesProvider().first(where: { $0.id.uuidString == agentID }) else { return }
        activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        selection = agentID; error = nil; draft = ""; blocks = []; pendingCount = 0
        selectedSessionOverride = nil; conversationPresented = true; sharedChatPresented = false; selectedTransfer = nil
        selectionTask?.cancel()
        let selectedWorkspace = windowWorkspace
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await conversation(workspace: selectedWorkspace, profile: profile)
                guard !Task.isCancelled, selection == agentID else { return }
                try await loadConversation(id)
                if selection == agentID { refresh(); activateSelectedConversation() }
            } catch {
                if !Task.isCancelled, selection == agentID {
                    self.error = "\(error.localizedDescription) You can start a new conversation from the resident's menu."
                }
            }
        }
    }

    /// A cancelled selection does not cancel session creation. All selections
    /// for this resident await one operation and persist its result exactly once.
    func conversation(workspace: String, profile: AgentProfile) async throws -> String {
        let key = Self.bindingKey(workspace: workspace, profileID: profile.id.uuidString)
        if let id = bindings[key] { return id }
        if let task = creationTasks[key] { return try await task.value }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let id = try await createConversation(workspace, profile)
            if let existing = boundProfileID(for: id), existing != profile.id {
                throw AgentWorldError.unavailable("This saved conversation belongs to another agent profile.")
            }
            profileHistory[id] = profile.id.uuidString
            bindings[key] = id
            persistConversationBindings()
            return id
        }
        creationTasks[key] = task
        defer { creationTasks[key] = nil }
        return try await task.value
    }

    func dismissConversation() {
        selectionTask?.cancel(); selection = nil; blocks = []; conversationBusy = false; pendingCount = 0; error = nil
        activationTask?.cancel(); activatingConversation = false; selectedSessionOverride = nil; conversationPresented = false; sharedChatPresented = false
    }

    func newConversation() {
        guard canInteract, let selection, let profileID = UUID(uuidString: selection), !conversationBusy,
              resetCurrentConversation(workspace: windowWorkspace, profileID: profileID) else { return }
        select(selection)
    }

    /// Forget only which chat to open next; the old chat remains owned by its
    /// original profile when opened from normal Locus history.
    @discardableResult
    func resetCurrentConversation(workspace: String, profileID: UUID) -> Bool {
        let key = Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)
        guard creationTasks[key] == nil, runners[key] == nil,
              bindings[key].map({ stateProvider($0).busy }) != true else { return false }
        bindings[key] = nil
        persistConversationBindings()
        return true
    }

    func submit(mode: WorkMode) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canInteract, !text.isEmpty, let profile = selectedProfile, let sessionID = selectedSessionID else { return }
        guard availabilityProvider(profile) == nil else {
            error = "Reconnect this agent's exact account and model before sending."; return
        }
        let selectedWorkspace = windowWorkspace
        let key = Self.bindingKey(workspace: selectedWorkspace, profileID: profile.id.uuidString)
        guard (queues[key]?.count ?? 0) < 20 else { error = "This resident already has 20 queued messages."; return }
        draft = ""; error = nil; queueErrors[key] = nil
        queues[key, default: []].append(QueuedTurn(text: text, mode: mode))
        refresh()
        guard runners[key] == nil else { return }
        let token = UUID()
        runnerTokens[key] = token
        runners[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if runnerTokens[key] == token { runners[key] = nil; runnerTokens[key] = nil }
                refresh()
            }
            while !Task.isCancelled, let next = queues[key]?.first {
                while stateProvider(sessionID).busy && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                }
                guard !Task.isCancelled, runnerTokens[key] == token, queues[key]?.isEmpty == false else { return }
                do {
                    try await dispatch(sessionID, selectedWorkspace, profile.id, next.text, next.mode)
                    if runnerTokens[key] == token, queues[key]?.isEmpty == false { queues[key]?.removeFirst() }
                } catch {
                    guard runnerTokens[key] == token, !Task.isCancelled else { return }
                    queueErrors[key] = error.localizedDescription
                    if selection == profile.id.uuidString, windowWorkspace == selectedWorkspace { self.error = error.localizedDescription; draft = next.text }
                    queues[key] = []
                    return
                }
                refresh()
            }
        }
    }

    func stopSelected() {
        guard let id = selectedSessionID, let selection else { return }
        let key = Self.bindingKey(workspace: windowWorkspace, profileID: selection)
        queues[key] = []; runners[key]?.cancel(); runners[key] = nil; runnerTokens[key] = nil
        stopConversation(id); refresh()
    }
    func openSelectedInLocus() { if let id = selectedSessionID { openConversation(id) } }
    func manageAgents() { manageProfiles() }

    /// The web world can request the editor, but profile data and saving stay
    /// in the native form. Creating a resident leaves this project's map open.
    func createAgent() {
        guard canCreateAgent, newAgentDraft == nil, let appModel else { return }
        newAgentDraft = appModel.newSavedAgentDraft()
    }

    func saveNewAgent(_ profile: AgentProfile) {
        guard canCreateAgent, newAgentDraft?.id == profile.id, let appModel,
              !appModel.agentProfiles.contains(where: { $0.id == profile.id }) else { return }
        appModel.agentTeamsModel.saveAgentProfile(profile)
        guard appModel.agentProfiles.contains(where: { $0.id == profile.id }) else { return }
        newAgentDraft = nil
        refresh()
    }

    func activateSelectedConversation() {
        guard canInteract, let sessionID = selectedSessionID, let appModel else { return }
        activationTask?.cancel()
        let token = UUID(); activationToken = token
        let expectedSelection = selection, expectedWorkspace = workspace
        let requiredOwnership = appModel.agentWorldOwnsPresentations
        activatingConversation = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.activationToken == token { self.activatingConversation = false } }
            do {
                try await appModel.activateAgentWorldConversation(sessionID, workspace: expectedWorkspace, stillCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.activationToken == token && self.selection == expectedSelection
                        && self.workspace == expectedWorkspace && self.conversationPresented && !self.sharedChatPresented
                        && self.canInteract && (!requiredOwnership || appModel.agentWorldOwnsPresentations)
                })
                guard !Task.isCancelled, self.selection == expectedSelection else { return }
                self.refresh()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// New/forked chats in the native workspace keep the current captain only
    /// when their durable saved-profile and workspace identities both match.
    func adoptForegroundConversation() {
        guard conversationPresented, !sharedChatPresented, let appModel,
              appModel.agentWorldOwnsPresentations, let selection,
              appModel.savedAgentProfileID(for: appModel.currentSessionID)?.uuidString == selection,
              SessionSummary.canonicalWorkspacePath(appModel.workspacePath) == workspace else { return }
        selectedSessionOverride = appModel.currentSessionID
        refresh()
    }

    func openSharedChat() {
        guard canInteract, let appModel else { return }
        selectionTask?.cancel(); activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        appModel.agentCrewChat.activate(workspace: workspace)
        conversationPresented = true; sharedChatPresented = true; selectedTransfer = nil
    }

    func openAgentControls(_ agentID: String? = nil) {
        guard canInteract else { return }
        if let id = agentID ?? selection ?? residents.first?.id { select(id) }
    }

    func openAttention(_ requestID: String) {
        refresh()
        guard canInteract, let request = attentionRequests.first(where: { $0.id == requestID }) else { return }
        showConversation(request.sessionID, profileID: request.agentID)
    }

    func openTransfer(_ transferID: String) {
        refresh()
        guard canInteract, let transfer = transfers.first(where: { $0.id == transferID }) else { return }
        selectedTransfer = transfer
    }

    func showTransferConversation(_ transfer: AgentWorldTransfer) {
        guard canInteract, transfers.contains(where: { $0.id == transfer.id }) else { return }
        selectedTransfer = nil
        showConversation(transfer.sessionID, profileID: transfer.toAgentID)
    }

    func showConversation(_ sessionID: String, profileID: String) {
        guard profilesProvider().contains(where: { $0.id.uuidString == profileID }) else { return }
        selectionTask?.cancel()
        selection = profileID; selectedSessionOverride = sessionID
        conversationPresented = true; sharedChatPresented = false; error = nil
        activateSelectedConversation()
    }

    var conversationContext: String? {
        guard let sessionID = selectedSessionOverride, let profile = selectedProfile,
              appModel?.savedAgentProfileID(for: sessionID) != profile.id else { return nil }
        return "Shared task · \(profile.name)"
    }
    nonisolated static func isSafeThemeID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }
    nonisolated static func isSafeResidentStyle(_ value: String) -> Bool {
        value == "mixed" || value == "pandas" || value == "explorers"
    }
    func setResidentStyle(_ value: String) {
        guard let activeScreen, activeScreen.screen.capabilities.contains("world.preferences"), Self.isSafeResidentStyle(value) else { return }
        residentStyle = value
        defaults?.set(value, forKey: "Locus.AgentWorld.residentStyle.v1." + activeScreen.id)
    }
    func setTheme(_ value: String) {
        guard let activeScreen, activeScreen.screen.capabilities.contains("world.preferences"), Self.isSafeThemeID(value) else { return }
        theme = value
        defaults?.set(value, forKey: "Locus.AgentWorld.theme.v1." + activeScreen.id)
    }

    var snapshot: [String: Any] {
        guard activeScreen?.screen.capabilities.contains("agents.read") == true else {
            return ["version": 1, "type": "snapshot", "agents": [], "theme": theme, "residentStyle": residentStyle, "projectName": "", "canCreateAgent": false]
        }
        var value: [String: Any] = ["version": 1, "type": "snapshot", "theme": theme, "residentStyle": residentStyle, "projectName": projectName, "canCreateAgent": canCreateAgent,
                                  "agents": residents.map { resident -> [String: Any] in
            // Route failures can contain provider names; the world needs only
            // the activity label. Detailed errors stay in the native panel.
            ["id": resident.id, "name": resident.name, "role": resident.role, "status": resident.status]
        }]
        if let selection { value["selectedAgentID"] = selection }
        value["attentionRequests"] = attentionRequests.map(\.snapshot)
        value["transfers"] = transfers.map(\.snapshot)
        return value
    }
}

extension AgentWorldModel {
    /// Test-only opt-in: local asset and bridge verification never starts a
    /// worker, installs a plugin, or changes the user's saved profiles.
    func openUITestFixture(root: String) {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_AGENT_WORLD_ROOT"] == root else { return }
        subscriptions.removeAll()
        isVisualFixture = true
        let profiles = [
            AgentProfile(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Atlas", model: "Fixture model", role: .researcher),
            AgentProfile(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Nova", model: "Fixture model", role: .implementer),
            AgentProfile(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, name: "Echo", model: "Fixture model", role: .reviewer),
            AgentProfile(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, name: "Orion", model: "Fixture model", role: .planner),
            AgentProfile(id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!, name: "Sage", model: "Fixture model", role: .generalist),
            AgentProfile(id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, name: "Pip", model: "Fixture model", role: .tester),
        ]
        profilesProvider = { profiles }
        availabilityProvider = { _ in nil }
        createConversation = { _, profile in "fixture-" + profile.id.uuidString }
        loadConversation = { _ in }
        stateProvider = { _ in .init(blocks: [ChatBlock(kind: .assistant, text: "Welcome to the outpost. Choose Chat to talk, or Assign work to begin a task.")]) }
        dispatch = { _, _, _, _, _ in throw AgentWorldError.unavailable("This is a visual test fixture; model calls are disabled.") }
        activityProvider = { profile, _ in
            switch profile.name {
            case "Nova": .init(status: "working", detail: "Fixture activity", busy: true)
            case "Echo": .init(status: "needs_attention", detail: "Fixture attention state", busy: true)
            default: nil
            }
        }
        stopConversation = { _ in }; openConversation = { _ in }; defaults = nil
        var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
        let screen = ExtensionPluginScreen(id: "agent-world", title: "Agent World", entrypoint: "ui/index.html", version: 1,
                                           capabilities: ["agents.read", "agents.interact", "world.preferences"])
        var plugin = ExtensionPlugin(id: "agent-world", name: "agent-world", displayName: "Agent World", description: nil,
                                     version: "1.0.0", author: nil, digest: "fixture", enabledGlobal: true,
                                     enabledWorkspaces: [], disabledWorkspaces: [], previousVersions: nil,
                                     skills: [], mcpServers: [], scripts: [], unsupported: [], updateAvailable: false, error: nil)
        plugin.root = root; plugin.screens = [screen]
        catalog = ExtensionsResponse(capabilities: capabilities, marketplaces: [], plugins: [plugin], skills: [],
                                     mcpServers: [], mcpPresets: [], errors: [], pendingUpdates: 0)
        open(pluginID: plugin.id, screenID: screen.id)
    }
}
