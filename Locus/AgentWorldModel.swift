import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

struct AgentWorldResident: Identifiable, Equatable, Encodable {
    let id: String
    let name: String
    let role: String
    let status: String
    var detail: String?
}

/// Display-only placement descriptions supplied by the installed renderer.
struct AgentWorldResidentPlacement: Equatable {
    let agentID: String
    let primary: String
    let secondary: String
}

/// Optional plugin window and display projection. Canonical conversation identity
/// and queued work belong to SavedAgentConversationService; plugin JavaScript sees
/// names, roles and activity labels, never transcripts or provider material.
@MainActor
final class AgentWorldModel: NSObject, ObservableObject, NSWindowDelegate {
    weak var appModel: AppModel?
    @Published var conversationPresented = false
    @Published var quartersPresented = false {
        didSet { if !quartersPresented { selectedPresentationID = nil } }
    }
    @Published var selectedPresentationID: String?
    var pluginPresentation: PluginWorldPresentation? { PluginWorldPresentation.load(screen: activeScreen) }
    @Published var sharedChatPresented = false
    @Published private(set) var profilePresented = false
    @Published private(set) var preparingConversation = false
    @Published private(set) var activatingConversation = false
    @Published var selectedTransfer: AgentWorldTransfer?
    @Published var newAgentDraft: AgentProfile?
    @Published private(set) var attentionRequests: [AgentWorldAttention] = []
    @Published private(set) var transfers: [AgentWorldTransfer] = []
    @Published private(set) var residents: [AgentWorldResident] = []
    @Published private(set) var availableScreens: [AvailableScreen] = []
    /// Plugin-owned windows (``locus.panels``), separate from Agent World.
    @Published private(set) var availablePanels: [PluginPanelWindowController.Target] = []
    @Published private(set) var selection: String?
    @Published private(set) var activeScreen: AvailableScreen?
    @Published private(set) var workspace = ""
    @Published private(set) var blocks: [ChatBlock] = []
    @Published private(set) var conversationBusy = false
    @Published private(set) var pendingCount = 0
    @Published var draft = ""
    @Published var error: String?
    @Published private(set) var residentPlacements: [String: AgentWorldResidentPlacement] = [:]
    @Published private(set) var activityCenterRequest = 0
    @Published private(set) var focusRequest = 0
    @Published var workspaceToolsRequest = 0
    @Published var graphicsError: String?
    @Published private(set) var renderEpoch = 0
    private var rendererRetryCount = 0
    var canRetryWorldScreen: Bool { activeScreen?.screen.version == 2 && graphicsError != nil && rendererRetryCount < 3 }

    func retryWorldScreen() {
        guard canRetryWorldScreen else { return }
        rendererRetryCount += 1
        graphicsError = nil
        renderEpoch += 1
    }
    @Published private(set) var worldPreferences: [String: Any] = [:]
    @Published private(set) var nativeNavigationRequest = 0
    private(set) var requestedNativeSurface = "agents"
    var projectName: String { URL(fileURLWithPath: workspace).lastPathComponent }
    var selectedProfile: AgentProfile? { profilesProvider().first { $0.id.uuidString == selection } }
    var selectedSessionID: String? { selectedSessionOverride ?? selection.flatMap { conversations.currentSessionID(for: Self.bindingKey(workspace: workspace, profileID: $0)) } }
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
    private var conversations = SavedAgentConversationService()
    private var profilesProvider: () -> [AgentProfile] = { [] }
    private var workspaceProvider: () -> String = { "" }
    private var availabilityProvider: (AgentProfile) -> String? = { _ in nil }
    private var stateProvider: (String) -> SavedAgentConversationState = { _ in .init() }
    private var loadConversation: (String) async throws -> Void = { _ in }
    private var activityProvider: (AgentProfile, String) -> SavedAgentConversationState? = { _, _ in nil }
    private var subscriptions = Set<AnyCancellable>()
    private var catalog = ExtensionsResponse.empty
    private var defaults: UserDefaults?
    private var window: NSWindow?
    private let pluginPanelWindows = PluginPanelWindowController()
    private var projectionRefreshTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionToken = UUID()
    private var activationTask: Task<Void, Never>?
    private var activationToken = UUID()
    private var selectedSessionOverride: String?
    private var windowWorkspace = ""
    private var isVisualFixture = false
    var visibilityChanged: ((Bool) -> Void)?

    func configure(
        extensions: ExtensionsModel, conversations: SavedAgentConversationService? = nil,
        profiles: @escaping () -> [AgentProfile], workspace: @escaping () -> String,
        availability: @escaping (AgentProfile) -> String?,
        state: @escaping (String) -> SavedAgentConversationState,
        create: @escaping (String, AgentProfile) async throws -> String,
        load: @escaping (String) async throws -> Void,
        activity: @escaping (AgentProfile, String) -> SavedAgentConversationState? = { _, _ in nil },
        dispatch: @escaping (String, String, UUID, String, WorkMode) async throws -> Void,
        stop: @escaping (String) -> Void, open: @escaping (String) -> Void,
        manage: @escaping () -> Void, defaults: UserDefaults?
    ) {
        profilesProvider = profiles; workspaceProvider = workspace; availabilityProvider = availability
        stateProvider = state; loadConversation = load; activityProvider = activity
        self.defaults = defaults
        if let conversations { self.conversations = conversations }
        else { self.conversations.configure(defaults: defaults, state: state, create: create, dispatch: dispatch) }
        self.conversations.queueFailed = { [weak self] workspace, profileID, text, message in
            guard let self, self.selection == profileID.uuidString, self.windowWorkspace == workspace else { return }
            self.error = message; self.draft = text
        }
        subscriptions.removeAll()
        self.conversations.objectWillChange.sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        if let appModel {
            appModel.objectWillChange.sink { [weak self] in self?.scheduleProjectionRefresh() }.store(in: &subscriptions)
            appModel.agentCrewChat.objectWillChange.sink { [weak self] in self?.scheduleProjectionRefresh() }.store(in: &subscriptions)
            appModel.runs.objectWillChange.sink { [weak self] in self?.scheduleProjectionRefresh() }.store(in: &subscriptions)
        }
        extensions.$extensions.sink { [weak self] value in
            self?.catalog = value
            self?.refresh()
        }.store(in: &subscriptions)
    }

    func boundProfileID(for sessionID: String) -> UUID? { conversations.boundProfileID(for: sessionID) }
    func hasPendingWork(profileID: UUID) -> Bool { conversations.hasPendingWork(profileID: profileID) }
    func bindConversation(_ sessionID: String, workspace: String, profileID: UUID) {
        conversations.bind(sessionID, workspace: workspace, profileID: profileID)
    }
    static func bindingKey(workspace: String, profileID: String) -> String {
        SavedAgentConversationService.bindingKey(workspace: workspace, profileID: profileID)
    }

    static func enabled(_ plugin: ExtensionPlugin, workspace: String) -> Bool {
        let canonical = SessionSummary.canonicalWorkspacePath(workspace)
        guard !plugin.disabledWorkspaces.contains(where: { SessionSummary.canonicalWorkspacePath($0) == canonical }) else { return false }
        return plugin.enabledGlobal || plugin.enabledWorkspaces.contains(where: { SessionSummary.canonicalWorkspacePath($0) == canonical })
    }

    /// Version 2 projects existing native change notifications into a bounded,
    /// coalesced display update. The renderer never polls canonical state.
    func scheduleProjectionRefresh() {
        guard activeScreen?.screen.version == 2, projectionRefreshTask == nil else { return }
        projectionRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            guard let self, !Task.isCancelled else { return }
            self.projectionRefreshTask = nil
            self.refresh()
        }
    }

    func refresh() {
        pluginPanelWindows.refresh(catalog: catalog)
        let currentWorkspace = SessionSummary.canonicalWorkspacePath(workspaceProvider())
        let panels: [PluginPanelWindowController.Target] = catalog.capabilities.pluginPanels == true
            ? catalog.plugins.filter { Self.enabled($0, workspace: currentWorkspace) && $0.error == nil }.flatMap { plugin in
                guard let root = plugin.root, root.hasPrefix("/") else { return [PluginPanelWindowController.Target]() }
                return (plugin.panels ?? []).filter(\.isSupported).map {
                    .init(pluginID: plugin.id, pluginName: plugin.displayName ?? plugin.name,
                          digest: plugin.digest, root: root, panel: $0)
                }
            } : []
        if availablePanels != panels { availablePanels = panels }
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
            if !stillEnabled || catalog.capabilities.pluginScreens != true
                || (activeScreen.screen.version == 2 && currentWorkspace != windowWorkspace) {
                // Revoke access synchronously before WebKit is torn down.
                self.activeScreen = nil
                selectionTask?.cancel()
                window?.close()
                return
            }
        }
        let targetWorkspace = activeScreen == nil ? currentWorkspace : windowWorkspace
        if workspace != targetWorkspace { workspace = targetWorkspace }
        let updated = profilesProvider().map { profile -> AgentWorldResident in
            let key = Self.bindingKey(workspace: targetWorkspace, profileID: profile.id.uuidString)
            let conversation = conversations.currentSessionID(for: key).map(stateProvider) ?? .init()
            let state = conversation.busy ? conversation : activityProvider(profile, targetWorkspace) ?? conversation
            let issue = availabilityProvider(profile)
            return AgentWorldResident(id: profile.id.uuidString, name: profile.name, role: profile.role.rawValue,
                                      status: issue != nil || (conversations.queueError(for: key) != nil && !state.busy) ? "failed" : state.status,
                                      detail: issue ?? conversations.queueError(for: key) ?? state.detail)
        }
        if Set(residents.map(\.id)) != Set(updated.map(\.id)) { residentPlacements = [:] }
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
            pendingCount = conversations.pendingCount(for: key)
        } else {
            conversationBusy = false; pendingCount = 0
        }
    }

    func openPanel(pluginID: String, panelID: String) {
        refresh()
        guard let appModel, let target = availablePanels.first(where: {
            $0.pluginID == pluginID && $0.panel.id == panelID
        }) else { error = "Install and enable this plugin for the project in Extensions."; return }
        pluginPanelWindows.open(target, workspace: workspaceProvider(), appModel: appModel)
    }

    func open(pluginID: String? = nil, screenID: String? = nil) {
        refresh()
        guard let choice = availableScreens.first(where: {
            (pluginID == nil || $0.pluginID == pluginID) && (screenID == nil || $0.screen.id == screenID)
        }) else { error = "Install and enable this plugin for the project in Extensions."; return }
        if window != nil, activeScreen == choice, windowWorkspace == SessionSummary.canonicalWorkspacePath(workspaceProvider()) {
            window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        window?.close()
        windowWorkspace = SessionSummary.canonicalWorkspacePath(workspaceProvider())
        workspace = windowWorkspace; activeScreen = choice; selection = nil; blocks = []; error = nil
        selectedSessionOverride = nil; conversationPresented = false; quartersPresented = false; sharedChatPresented = false; selectedTransfer = nil
        profilePresented = false; preparingConversation = false; selectionToken = UUID()
        residentPlacements = [:]; activityCenterRequest = 0
        loadWorldPreferences(for: choice)
        graphicsError = nil; rendererRetryCount = 0; renderEpoch += 1; draft = ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(choice.screen.title) · \(projectName)"
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = pluginPresentation == nil ? nil : NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: AgentWorldView(model: self))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()

    }

    func windowWillClose(_ notification: Notification) {
        visibilityChanged?(false); visibilityChanged = nil
        projectionRefreshTask?.cancel(); projectionRefreshTask = nil
        selectionTask?.cancel(); activationTask?.cancel()
        selectionToken = UUID(); activationToken = UUID(); preparingConversation = false; activatingConversation = false
        appModel?.agentWorldOwnsPresentations = false
        newAgentDraft = nil
        window?.contentView = nil; window = nil; activeScreen = nil
        // Runners and the application's workers intentionally outlive the window.
    }
    func windowDidBecomeKey(_ notification: Notification) { appModel?.agentWorldOwnsPresentations = true }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged?(false) }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged?(true); scheduleProjectionRefresh() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window?.occlusionState.contains(.visible) == true
        visibilityChanged?(visible)
        if visible { scheduleProjectionRefresh() }
    }

    /// Focus the map camera and close any open conversation panel.
    func focusResident(_ agentID: String) {
        guard canInteract, profilesProvider().contains(where: { $0.id.uuidString == agentID }) else { return }
        dismissConversation()
        selection = agentID
        focusRequest += 1
        refresh()
    }

    func chooseResident(_ agentID: String) {
        if quartersPresented { openAgentProfile(agentID) }
        else { openResidentMapChat(agentID) }
    }

    func clearWorldSelection() {
        dismissConversation()
        quartersPresented = false
        refresh()
    }

    func residentConversations(for agentID: String) -> [SessionSummary] {
        guard let profileID = UUID(uuidString: agentID), let appModel else { return [] }
        return appModel.sessions.filter {
            !$0.isArchived && $0.belongsToWorkspace(workspace)
                && (appModel.savedAgentProfileID(for: $0.id) ?? boundProfileID(for: $0.id)) == profileID
        }.sorted { $0.mtime > $1.mtime }
    }

    /// Map selection stays on the map. Existing chats resume in the floating
    /// panel; starting a first chat remains an explicit action.
    func openResidentMapChat(_ agentID: String) {
        guard canInteract, profilesProvider().contains(where: { $0.id.uuidString == agentID }) else { return }
        if selection == agentID, conversationPresented, !sharedChatPresented, !profilePresented {
            focusRequest += 1
            refresh()
            return
        }
        selectionTask?.cancel(); selectionToken = UUID(); preparingConversation = false
        activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        selection = agentID; focusRequest += 1
        conversationPresented = true; sharedChatPresented = false; profilePresented = false
        selectedTransfer = nil; error = nil; blocks = []; pendingCount = 0
        selectedSessionOverride = residentConversations(for: agentID).first?.id
        refresh()
        if selectedSessionOverride != nil { activateSelectedConversation() }
    }

    func select(_ agentID: String) {
        guard canInteract, let profile = profilesProvider().first(where: { $0.id.uuidString == agentID }) else { return }
        activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        if selection != agentID { focusRequest += 1 }
        selection = agentID; error = nil; draft = ""; blocks = []; pendingCount = 0
        selectedSessionOverride = nil; conversationPresented = true; sharedChatPresented = false; selectedTransfer = nil; profilePresented = false
        selectionTask?.cancel()
        let token = UUID(); selectionToken = token; preparingConversation = true
        let selectedWorkspace = windowWorkspace
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if selectionToken == token { preparingConversation = false } }
            var sessionID: String?
            do {
                let id = try await conversation(workspace: selectedWorkspace, profile: profile)
                sessionID = id
                guard !Task.isCancelled, selectionToken == token, selection == agentID else { return }
                try await loadConversation(id)
                guard !Task.isCancelled, selectionToken == token, selection == agentID else { return }
                refresh(); activateSelectedConversation()
            } catch {
                if !Task.isCancelled, selectionToken == token, selection == agentID {
                    recordConversationFailure(error, sessionID: sessionID, workspace: selectedWorkspace, profileID: profile.id)
                }
            }
        }
    }

    /// A cancelled selection does not cancel session creation. All selections
    /// for this resident await one operation and persist its result exactly once.
    func conversation(workspace: String, profile: AgentProfile) async throws -> String {
        try await conversations.conversation(workspace: workspace, profile: profile)
    }

    func dismissConversation() {
        selectionTask?.cancel(); selection = nil; blocks = []; conversationBusy = false; pendingCount = 0; error = nil
        activationTask?.cancel(); activatingConversation = false; selectedSessionOverride = nil; conversationPresented = false; sharedChatPresented = false
        selectionToken = UUID(); preparingConversation = false; profilePresented = false
    }

    func newConversation() {
        guard let selection else { return }
        newConversation(for: selection)
    }

    func canStartConversation(for agentID: String) -> Bool {
        guard canInteract, let profile = profilesProvider().first(where: { $0.id.uuidString == agentID }) else { return false }
        let key = Self.bindingKey(workspace: windowWorkspace, profileID: profile.id.uuidString)
        return !hasPendingWork(profileID: profile.id)
            && conversations.currentSessionID(for: key).map({ stateProvider($0).busy }) != true
            && (selection != agentID || selectedSessionID.map({ stateProvider($0).busy }) != true)
    }

    func newConversation(for agentID: String) {
        guard canStartConversation(for: agentID) else { return }
        if let appModel, UUID(uuidString: agentID) == appModel.agentTeamsModel.primaryCompanionID {
            appModel.openCompanionMainConversation()
            return
        }
        guard let profileID = UUID(uuidString: agentID),
              resetCurrentConversation(workspace: windowWorkspace, profileID: profileID) else { return }
        select(agentID)
    }

    /// Board handoffs stay in this world and carry the chosen saved profile.
    /// Only prepare a draft: the user still chooses when to send it.
    func openBoardCard(_ card: BoardCard, profileID: String) async throws {
        guard canInteract, quartersPresented, !isVisualFixture, let appModel,
              canStartConversation(for: profileID),
              let profile = profilesProvider().first(where: { $0.id.uuidString == profileID }) else {
            throw SavedAgentConversationError.unavailable("Choose an available agent before opening this card.")
        }
        let project = workspace
        let store = BoardStore.shared(workspacePath: project)
        guard let current = store.cards.first(where: { $0.id == card.id }) else {
            throw SavedAgentConversationError.unavailable("This card is no longer on the project’s board.")
        }
        guard !appModel.chatNavigationDisabled else {
            throw SavedAgentConversationError.unavailable("Finish the current chat change before opening this card.")
        }
        let session = try await appModel.createSavedAgentConversation(profile, workspace: project)
        try await appModel.activateSavedAgentConversation(session.id, workspace: project,
            expectedProfileID: profile.id, stillCurrent: { [weak self] in
                self?.workspace == project && self?.quartersPresented == true && self?.canInteract == true
            })
        showConversation(session.id, profileID: profileID)
        appModel.draftText = store.chatPrompt(for: current)
        appModel.composerFocusToken = UUID()
    }

    /// Profile inspection never creates/resumes a chat or changes the main
    /// window's selected saved agent. It remains useful when history is missing.
    func openAgentProfile(_ agentID: String? = nil) {
        guard canInteract, let id = agentID ?? selection,
              profilesProvider().contains(where: { $0.id.uuidString == id }) else { return }
        selectionTask?.cancel(); selectionToken = UUID(); preparingConversation = false
        activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        if selection != id { selectedSessionOverride = nil; error = nil; blocks = [] }
        quartersPresented = true
        selection = id; focusRequest += 1; conversationPresented = true; sharedChatPresented = false; profilePresented = true
        refresh()
    }

    func showSelectedChat() {
        profilePresented = false
        if let selection {
            if let selectedSessionOverride { showConversation(selectedSessionOverride, profileID: selection, opensQuarters: quartersPresented) }
            else { select(selection) }
        }
    }

    /// Inspect saved activity without starting or resuming a conversation.
    func showSelectedTools() {
        guard canInteract, selectedProfile != nil else { return }
        selectionTask?.cancel(); selectionToken = UUID(); preparingConversation = false
        activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        profilePresented = false
        sharedChatPresented = false
        conversationPresented = true
    }

    func openResidentConversation(_ session: SessionSummary) {
        guard canInteract, let profile = selectedProfile, (session.savedAgentProfileID ?? boundProfileID(for: session.id)) == profile.id,
              !session.isArchived, session.belongsToWorkspace(workspace) else { return }
        profilePresented = false
        showConversation(session.id, profileID: profile.id.uuidString, opensQuarters: quartersPresented)
    }

    /// Only a confirmed missing/archived chat loses its current binding. Network
    /// failures remain retryable; historical profile ownership is always kept.
    func recordConversationFailure(_ failure: Error, sessionID: String?, workspace: String, profileID: UUID) {
        guard selection == profileID.uuidString, self.workspace == SessionSummary.canonicalWorkspacePath(workspace),
              sessionID == nil || selectedSessionID == sessionID else { return }
        let missing: Bool
        if case SavedAgentConversationError.conversationUnavailable = failure { missing = true }
        else { let value = failure as NSError; missing = value.domain == "Locus.Backend" && value.code == 404 }
        if missing, let sessionID {
            conversations.clearMissingBinding(sessionID: sessionID, workspace: workspace, profileID: profileID)
            if selectedSessionOverride == sessionID { selectedSessionOverride = nil }
            error = "This chat is no longer available. Start a new chat for \(selectedProfile?.name ?? "this resident"), or choose an existing chat from their agent details."
        } else { error = failure.localizedDescription }
        refresh()
    }

    /// Forget only which chat to open next; the old chat remains owned by its
    /// original profile when opened from normal Locus history.
    @discardableResult
    func resetCurrentConversation(workspace: String, profileID: UUID) -> Bool {
        conversations.resetCurrentConversation(workspace: workspace, profileID: profileID)
    }

    func submit(mode: WorkMode) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canInteract, !text.isEmpty, let profile = selectedProfile, let sessionID = selectedSessionID else { return }
        guard availabilityProvider(profile) == nil else { error = "Reconnect this agent's exact account and model before sending."; return }
        do {
            try conversations.enqueue(text: text, mode: mode, sessionID: sessionID, workspace: windowWorkspace, profileID: profile.id)
            draft = ""; error = nil; refresh()
        } catch { self.error = error.localizedDescription }
    }

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
        guard canInteract, !profilePresented, let sessionID = selectedSessionID, let appModel else { return }
        activationTask?.cancel()
        let token = UUID(); activationToken = token
        let expectedSelection = selection, expectedWorkspace = workspace
        let expectedProfileID = selectedSessionOverride == nil ? selectedProfile?.id : nil
        let requiredOwnership = appModel.agentWorldOwnsPresentations
        activatingConversation = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.activationToken == token { self.activatingConversation = false } }
            do {
                try await appModel.activateSavedAgentConversation(sessionID, workspace: expectedWorkspace, expectedProfileID: expectedProfileID, stillCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.activationToken == token && self.selection == expectedSelection
                        && self.workspace == expectedWorkspace && self.conversationPresented && !self.sharedChatPresented && !self.profilePresented
                        && self.canInteract && (!requiredOwnership || appModel.agentWorldOwnsPresentations)
                })
                guard !Task.isCancelled, self.selection == expectedSelection else { return }
                self.refresh()
            } catch {
                if !Task.isCancelled, self.activationToken == token, let expectedSelection, let profileID = UUID(uuidString: expectedSelection) {
                    self.recordConversationFailure(error, sessionID: sessionID, workspace: expectedWorkspace, profileID: profileID)
                }
            }
        }
    }

    /// New/forked chats in the native workspace keep the current captain only
    /// when their durable saved-profile and workspace identities both match.
    func adoptForegroundConversation() {
        guard conversationPresented, !sharedChatPresented, !profilePresented, !preparingConversation, !activatingConversation, let appModel,
              appModel.agentWorldOwnsPresentations, let selection,
              appModel.savedAgentProfileID(for: appModel.currentSessionID)?.uuidString == selection,
              appModel.sessions.first(where: { $0.id == appModel.currentSessionID })?.belongsToWorkspace(workspace) == true else { return }
        selectedSessionOverride = appModel.currentSessionID
        refresh()
    }

    func openSharedChat() {
        guard canInteract, let appModel else { return }
        selectionTask?.cancel(); activationTask?.cancel(); activationToken = UUID(); activatingConversation = false
        selectionToken = UUID(); preparingConversation = false; profilePresented = false
        appModel.agentCrewChat.activate(workspace: workspace)
        quartersPresented = true
        conversationPresented = true; sharedChatPresented = true; selectedTransfer = nil
    }

    func openAgentControls(_ agentID: String? = nil) {
        guard canInteract else { return }
        selectedPresentationID = nil
        if let id = agentID ?? selection { openAgentProfile(id) }
        quartersPresented = true
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

    func showConversation(_ sessionID: String, profileID: String, opensQuarters: Bool = true) {
        guard profilesProvider().contains(where: { $0.id.uuidString == profileID }) else { return }
        selectionTask?.cancel()
        selectionToken = UUID(); preparingConversation = false; profilePresented = false
        quartersPresented = opensQuarters
        selection = profileID; selectedSessionOverride = sessionID
        conversationPresented = true; sharedChatPresented = false; error = nil
        activateSelectedConversation()
    }

    var conversationContext: String? {
        guard let sessionID = selectedSessionOverride, let profile = selectedProfile,
              appModel?.savedAgentProfileID(for: sessionID) != profile.id else { return nil }
        return "Shared task · \(profile.name)"
    }
    func requestActivityCenter() {
        guard activeScreen?.screen.capabilities.contains("agents.read") == true else { return }
        appModel?.activity.openActivityCenter()
        activityCenterRequest += 1
    }

    func receiveResidentPlacements(_ placements: [AgentWorldResidentPlacement]) {
        guard activeScreen?.screen.capabilities.contains("agents.read") == true else { return }
        let known = Set(residents.map(\.id))
        guard placements.count <= 500, placements.allSatisfy({ known.contains($0.agentID) }),
              Set(placements.map(\.agentID)).count == placements.count else { return }
        let updated = Dictionary(uniqueKeysWithValues: placements.map { ($0.agentID, $0) })
        if residentPlacements != updated { residentPlacements = updated }
    }


}

extension AgentWorldModel {
    /// Test-only opt-in: local asset and bridge verification never starts a
    /// worker, installs a plugin, or changes the user's saved profiles.
    func openUITestFixture(root: String) {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_AGENT_WORLD_ROOT"] == root else { return }
        subscriptions.removeAll()
        self.conversations.objectWillChange.sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        isVisualFixture = true
        let profiles = [
            AgentProfile(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Atlas", model: "Fixture model", role: .researcher),
            AgentProfile(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Nova", model: "Fixture model", role: .implementer),
            AgentProfile(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, name: "Echo", model: "Fixture model", role: .reviewer),
            AgentProfile(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, name: "Orion", model: "Fixture model", role: .planner),
            AgentProfile(id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!, name: "Sage", model: "Fixture model", role: .generalist),
            AgentProfile(id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!, name: "Pip", model: "Fixture model", role: .tester),
        ]
        appModel?.agentProfiles = profiles
        profilesProvider = { profiles }
        availabilityProvider = { _ in nil }
        let fixtureCreate: (String, AgentProfile) async throws -> String = { _, profile in "fixture-" + profile.id.uuidString }
        loadConversation = { [weak self] id in
            guard let self, let app = self.appModel, let profileID = self.boundProfileID(for: id),
                  let profile = profiles.first(where: { $0.id == profileID }) else { return }
            if !app.sessions.contains(where: { $0.id == id }) {
                app.sessions.append(SessionSummary(id: id, name: id, preview: "Deck workspace preview", mtime: Date().timeIntervalSince1970,
                    size: 0, title: "Deck workspace", cwd: self.workspace, agentProfileID: profileID.uuidString,
                    agentName: profile.name, model: "Fixture model"))
            }
            app.currentSessionID = id
            app.blocks = [ChatBlock(kind: .assistant, text: "Welcome aboard. Your browser, task board, and calendar are beside this conversation.")]
        }
        stateProvider = { _ in .init(blocks: [ChatBlock(kind: .assistant, text: "Choose Chat to talk, or Assign work to begin a task.")]) }
        let fixtureDispatch: (String, String, UUID, String, WorkMode) async throws -> Void = { _, _, _, _, _ in throw SavedAgentConversationError.unavailable("This is a visual test fixture; model calls are disabled.") }
        activityProvider = { profile, _ in
            switch profile.name {
            case "Nova": .init(status: "working", detail: "Fixture activity", busy: true)
            case "Echo": .init(status: "needs_attention", detail: "Fixture attention state", busy: true)
            default: nil
            }
        }
        conversations.configure(defaults: nil, state: stateProvider, create: fixtureCreate, dispatch: fixtureDispatch)
        defaults = nil
        var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
        let descriptorURL = URL(fileURLWithPath: root).appendingPathComponent(".codex-plugin/plugin.json")
        let descriptor = (try? Data(contentsOf: descriptorURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let manifestScreens = (descriptor?["locus"] as? [String: Any])?["screens"] as? [[String: Any]]
        let declaredScreen = manifestScreens?.first.flatMap { row -> ExtensionPluginScreen? in
            guard let data = try? JSONSerialization.data(withJSONObject: row),
                  let value = try? JSONDecoder().decode(ExtensionPluginScreen.self, from: data), value.isSupported else { return nil }
            return value
        }
        let screen = declaredScreen ?? ExtensionPluginScreen(id: "agent-world", title: "Agent Worlds", entrypoint: "ui/index.html", version: 2,
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


extension AgentWorldModel {
    /// Disposable visual state only. The migration never reads or writes native
    /// conversation/history keys. Legacy visual keys remain available for rollback.
    static func worldPreferenceStorageKey(screenID: String, workspace: String) -> String {
        let canonical = SessionSummary.canonicalWorkspacePath(workspace)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Locus.AgentWorlds.preferences.v2." + screenID + "." + digest
    }

    private func loadWorldPreferences(for screen: AvailableScreen) {
        let key = Self.worldPreferenceStorageKey(screenID: screen.id, workspace: workspace)
        if let data = defaults?.data(forKey: key),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           AgentWorldBridgeContract.validPreferences(saved) {
            worldPreferences = saved
            return
        }
        if defaults?.object(forKey: key) != nil {
            // A pre-existing malformed namespace is not a first-run migration.
            // Retain its bytes for recovery and await an explicit visual edit/reset.
            worldPreferences = [:]
            return
        }
        worldPreferences = LegacyAgentWorldPreferenceMigration.values(
            defaults: defaults, screenID: screen.id, presentation: pluginPresentation,
            authorizedAgentIDs: Set(profilesProvider().prefix(500).map { $0.id.uuidString }))
        if let data = try? JSONSerialization.data(withJSONObject: worldPreferences, options: [.sortedKeys]) {
            defaults?.set(data, forKey: key)
        }
    }

    func updateWorldPreference(key: String, value: Any) throws {
        guard let activeScreen, activeScreen.screen.capabilities.contains("world.preferences") else {
            throw AgentWorldBridgeContract.Failure(code: "denied", message: "World preferences are not authorized.")
        }
        var updated = worldPreferences
        updated[key] = value
        guard AgentWorldBridgeContract.validPreferences(updated),
              let data = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]) else {
            throw AgentWorldBridgeContract.Failure(code: "quota", message: "World preferences exceed their storage limit.")
        }
        defaults?.set(data, forKey: Self.worldPreferenceStorageKey(screenID: activeScreen.id, workspace: workspace))
        worldPreferences = updated
        if key == pluginPresentation?.contextEnabledPreferenceKey, value as? Bool == false { selectedPresentationID = nil }
    }

    func resetWorldPreferences() throws {
        guard let activeScreen, activeScreen.screen.capabilities.contains("world.preferences") else {
            throw AgentWorldBridgeContract.Failure(code: "denied", message: "World preferences are not authorized.")
        }
        defaults?.set(Data("{}".utf8), forKey: Self.worldPreferenceStorageKey(screenID: activeScreen.id, workspace: workspace))
        worldPreferences = [:]; selectedPresentationID = nil
    }

    func openWorldNativeSurface(_ surface: String, agentID: String?) {
        if surface == "activity" { requestActivityCenter(); return }
        openAgentControls(agentID)
        requestedNativeSurface = surface
        nativeNavigationRequest += 1
    }

    @discardableResult
    func openPluginPresentation(_ id: String) -> Bool {
        guard canInteract, let presentation = pluginPresentation,
              presentation.presentations[id] != nil else { return false }
        guard id == presentation.defaultPresentationID || worldPreferences[presentation.contextEnabledPreferenceKey] as? Bool != false else { return false }
        selectedPresentationID = id == presentation.defaultPresentationID ? nil : id
        quartersPresented = true
        return true
    }

    func openWorldPresentation(_ presentationID: String) throws {
        guard openPluginPresentation(presentationID) else {
            throw AgentWorldBridgeContract.Failure(code: "not_found", message: "The requested native presentation is not available.")
        }
    }

    func worldDisplayState(capabilities: Set<String>) -> [String: Any] {
        func displayText(_ value: String, maximum: Int = 256) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value > 31 && !(127...159).contains($0.value) }.prefix(maximum)))
        }
        let knownResidents = capabilities.contains("agents.read") ? Array(residents.prefix(500)) : []
        let ids = Set(knownResidents.map(\.id))
        let statuses = ["idle", "working", "needs_attention", "completed", "failed", "queued"]
        let agents: [[String: Any]] = knownResidents.map {
            ["id": $0.id, "name": displayText($0.name), "role": displayText($0.role), "status": statuses.contains($0.status) ? $0.status : "idle"]
        }
        let attention = attentionRequests.filter { ids.contains($0.agentID) }.prefix(256).map { request -> [String: Any] in
            ["id": request.id, "agentID": request.agentID, "kind": request.kind == "input" ? "input" : "approval", "title": displayText(request.title)]
        }
        let deliveries = transfers.filter {
            ids.contains($0.fromAgentID) && ids.contains($0.toAgentID) && $0.fromAgentID != $0.toAgentID
                && $0.occurredAt.timeIntervalSince1970.isFinite && (0...253402300799).contains($0.occurredAt.timeIntervalSince1970)
        }.suffix(128).map { transfer -> [String: Any] in
            ["id": transfer.id, "fromAgentID": transfer.fromAgentID, "toAgentID": transfer.toAgentID,
             "kind": transfer.kind == "artifact" ? "artifact" : "handoff", "title": displayText(transfer.title), "occurredAt": transfer.occurredAt.timeIntervalSince1970]
        }
        var state: [String: Any] = ["agents": agents, "projectName": capabilities.contains("agents.read") ? displayText(projectName) : "",
                                   "preferences": worldPreferences, "attentionRequests": attention, "transfers": deliveries,
                                   "canCreateAgent": capabilities.contains("agents.interact") && canCreateAgent,
                                   "nativeChrome": true, "focusRequest": max(0, focusRequest), "activityCenterRequest": max(0, activityCenterRequest)]
        if let selection, ids.contains(selection) { state["selectedAgentID"] = selection }
        return state
    }
}
