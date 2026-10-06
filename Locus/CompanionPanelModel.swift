import Combine
import Foundation

/// Selection and loading for the inspector only. Canonical chats, drafts,
/// transcripts, execution and approvals remain in the existing app stores.
@MainActor
final class CompanionPanelModel: ObservableObject {
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var workspace = ""
    @Published private(set) var profileID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isCreating = false
    @Published private var sendingSessionIDs: Set<String> = []
    @Published var error: String?
    @Published var mode: WorkMode = .ask

    private weak var app: AppModel?
    private var selectionRevision = UUID()
    private var loadedSessionID: String?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var creationTask: Task<Void, Never>?
    private var sendingTasks: [String: Task<Void, Never>] = [:]
    private var catalogObservation: AnyCancellable?
    private var dispatch: ((String, String, UUID, String, WorkMode) async throws -> Void)?

    func configure(app: AppModel,
                   dispatch: ((String, String, UUID, String, WorkMode) async throws -> Void)? = nil) {
        self.app = app
        self.dispatch = dispatch ?? { [weak app] id, workspace, profileID, text, mode in
            guard let app else { throw CancellationError() }
            try await app.sendSavedAgentTurn(sessionID: id, workspace: workspace, profileID: profileID,
                                            text: text, mode: mode, preservingForeground: true)
        }
        // Catalog changes intentionally do not invalidate the entire AppModel.
        // Observe this store only for the panel's history and selected identity.
        catalogObservation = app.sessionCatalog.$snapshot.dropFirst().sink { [weak self] snapshot in
            self?.catalogDidChange(snapshot)
        }
    }

    var profile: AgentProfile? {
        guard let app, profileID == app.agentTeamsModel.primaryCompanionID else { return nil }
        return app.primaryCompanionProfile
    }

    var chats: [SessionSummary] { app?.companionChats(in: workspace) ?? [] }
    /// Relative transcript artifacts resolve in the selected chat's execution
    /// folder; its canonical root remains the independent routing scope.
    var conversationWorkspacePath: String {
        guard selectionIsCurrent, let id = selectedSessionID,
              let session = app?.sessionCatalog.snapshot.sessionsByID[id] else { return workspace }
        return session.executionPath?.nilIfEmpty ?? session.cwd?.nilIfEmpty ?? workspace
    }
    var isSending: Bool { selectedSessionID.map { sendingSessionIDs.contains($0) } ?? false }
    var sendingTask: Task<Void, Never>? { selectedSessionID.flatMap { sendingTasks[$0] } }
    var isForegroundConversation: Bool { selectedSessionID != nil && selectedSessionID == app?.currentSessionID }
    var blocks: [ChatBlock] {
        guard selectionIsCurrent, let id = selectedSessionID, loadedSessionID == id else { return [] }
        return app?.paneBlocks(for: id) ?? []
    }
    var state: SavedAgentConversationState {
        guard selectionIsCurrent, let id = selectedSessionID else { return .init() }
        return app?.savedAgentConversationState(id) ?? .init()
    }
    var draft: String {
        get {
            guard selectionIsCurrent, let id = selectedSessionID, !isForegroundConversation else { return "" }
            return app?.paneDraft(for: id) ?? ""
        }
        set {
            guard selectionIsCurrent, let id = selectedSessionID, !isForegroundConversation else { return }
            objectWillChange.send()
            app?.setPaneDraft(newValue, for: id)
        }
    }
    var availabilityIssue: String? {
        guard let app, let profile else { return "Set up your companion to start a conversation." }
        guard scopeIsCurrent else { return "This project changed. Reopen your companion to continue." }
        if isForegroundConversation { return "This conversation is open in the center. Start another conversation to chat alongside it." }
        guard app.isAgentOnline else { return "Your companion is ready. Reconnect Locus to continue." }
        let effectiveProfile = selectedSessionID.map { app.agentChatProfile(profile, sessionID: $0) } ?? profile
        do { _ = try app.agentProfileProvider(effectiveProfile); return nil }
        catch { return error.localizedDescription }
    }
    var canSend: Bool {
        selectionIsCurrent && selectedSessionID != nil && loadedSessionID == selectedSessionID && !isLoading && !isSending
            && !isCreating && !state.busy && availabilityIssue == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [.ask, .work].contains(mode)
    }
    var canRetryLoading: Bool {
        selectionIsCurrent && selectedSessionID != nil && loadedSessionID != selectedSessionID
            && !isLoading && app?.isAgentOnline == true
    }
    private var scopeIsCurrent: Bool {
        guard let app, profile != nil else { return false }
        return profileID == app.agentTeamsModel.primaryCompanionID && workspace == app.companionWorkspacePath
    }
    private var selectionIsCurrent: Bool {
        scopeIsCurrent && chats.contains { $0.id == selectedSessionID }
    }

    /// Opening the panel only selects and reads a saved conversation. Prefer a
    /// different chat from the center so both drafts can remain independent.
    func activate() {
        guard let app else { return }
        let newWorkspace = app.companionWorkspacePath
        let newProfileID = app.agentTeamsModel.primaryCompanionID
        if workspace != newWorkspace || profileID != newProfileID {
            invalidateSelection()
            workspace = newWorkspace
            profileID = newProfileID
        }
        guard profile != nil else {
            if selectedSessionID != nil { invalidateSelection() }
            return
        }
        if let id = selectedSessionID, let selected = chats.first(where: { $0.id == id }) {
            if !isLoading && loadedSessionID != id { select(selected) }
            return
        }
        let remembered = app.lastSidebarSessionIDs[app.companionSessionKey(workspace: workspace)]
        let candidates = chats.filter { $0.id != app.currentSessionID }
        if let selected = candidates.first(where: { $0.id == remembered }) ?? candidates.first {
            select(selected)
        } else if selectedSessionID != nil {
            invalidateSelection()
        }
    }

    func select(_ session: SessionSummary) {
        guard let app, scopeIsCurrent, let profileID,
              chats.contains(where: { $0.id == session.id }), session.belongsToWorkspace(workspace),
              session.savedAgentProfileID == profileID else { return }
        if selectedSessionID == session.id, (isLoading || loadedSessionID == session.id) { return }
        invalidateSelection()
        selectedSessionID = session.id
        guard app.isAgentOnline else { error = "Reconnect Locus to load this conversation."; return }
        let revision = selectionRevision
        let requestedWorkspace = workspace
        isLoading = true
        loadTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer {
                if selectionRevision == revision { isLoading = false; loadTask = nil }
            }
            do {
                let response = try await app.backend.get("/api/sessions/\(session.id)", as: CompanionPanelConversation.self)
                try Task.checkCancellation()
                guard selectionRevision == revision, scopeIsCurrent,
                      selectedSessionID == session.id else { return }
                guard response.identity.matches(sessionID: session.id, profileID: profileID, workspace: requestedWorkspace),
                      response.detail.archived != true else {
                    throw SavedAgentConversationError.unavailable("This conversation no longer belongs to your companion and project, or is archived.")
                }
                // A read of a center conversation must not overwrite its live
                // transcript or draft. Its normal full view remains authoritative.
                if session.id != app.currentSessionID {
                    app.splitPaneBlocks[session.id] = ChatTranscriptBuilder.blocks(from: response.detail.messages)
                }
                loadedSessionID = session.id
                app.rememberCompanionPanelSession(session.id, workspace: requestedWorkspace)
            } catch {
                guard !Task.isCancelled, selectionRevision == revision, scopeIsCurrent else { return }
                loadedSessionID = nil
                self.error = error.localizedDescription
            }
        }
    }

    func retryLoading() {
        guard !isLoading else { return }
        if let id = selectedSessionID, let session = chats.first(where: { $0.id == id }) {
            select(session)
        } else {
            activate()
        }
    }

    func createConversation() {
        guard !isCreating else { return }
        activate()
        guard let app, let profile, scopeIsCurrent, !isCreating else { return }
        guard app.isAgentOnline else { error = "Reconnect Locus before opening a new conversation."; return }
        let requestedWorkspace = workspace
        let revision = selectionRevision
        isCreating = true
        error = nil
        creationTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer { isCreating = false; creationTask = nil }
            do {
                let session = try await app.createSavedAgentConversation(profile, workspace: requestedWorkspace,
                                                                         preservingForeground: true)
                guard selectionRevision == revision, scopeIsCurrent,
                      workspace == requestedWorkspace, profileID == profile.id else { return }
                select(session)
            } catch {
                guard selectionRevision == revision, scopeIsCurrent else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func send() {
        guard canSend, let app, let id = selectedSessionID, let profileID, let dispatch else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDraft = draft
        let requestedWorkspace = workspace
        let requestedMode = mode
        let revision = selectionRevision
        sendingSessionIDs.insert(id)
        error = nil
        sendingTasks[id] = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer { sendingSessionIDs.remove(id); sendingTasks[id] = nil }
            do {
                // Revalidate actual durable ownership immediately before any
                // dispatch; a cached catalog alone cannot authorize a turn.
                let response = try await app.backend.get("/api/sessions/\(id)", as: CompanionPanelConversation.self)
                try Task.checkCancellation()
                guard selectionRevision == revision, scopeIsCurrent, selectedSessionID == id,
                      id != app.currentSessionID else { throw CancellationError() }
                guard response.identity.matches(sessionID: id, profileID: profileID, workspace: requestedWorkspace),
                      response.detail.archived != true else {
                    throw SavedAgentConversationError.unavailable("This conversation no longer belongs to your companion and project, or is archived.")
                }
                try await dispatch(id, requestedWorkspace, profileID, text, requestedMode)
                // Acceptance only clears the exact submitted draft. Later edits
                // or a different selected chat remain untouched.
                if id != app.currentSessionID, app.paneDraft(for: id) == originalDraft {
                    app.setPaneDraft("", for: id)
                }
            } catch {
                guard selectionRevision == revision, scopeIsCurrent else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func stop() {
        guard selectionIsCurrent, let id = selectedSessionID, !isForegroundConversation else { return }
        sendingTasks[id]?.cancel()
        app?.stopGoalTurn(sessionID: id)
    }

    /// Deliberately entering the normal conversation is the only panel action
    /// that may replace the center, for attachments or its full approval UI.
    func openFullConversation() {
        guard let app, scopeIsCurrent, let id = selectedSessionID,
              let session = chats.first(where: { $0.id == id }) else { return }
        if id == app.currentSessionID { return }
        guard app.isAgentOnline, app.canSwitchToCompanionChat else {
            error = "Finish or stop the active foreground run before opening this conversation."
            return
        }
        app.resume(session)
    }

    private func catalogDidChange(_ snapshot: SessionCatalogSnapshot) {
        objectWillChange.send()
        guard let id = selectedSessionID else { return }
        // @Published emits before the backing snapshot changes. Validate the
        // incoming value directly, never the previous catalog via `chats`.
        guard let session = snapshot.sessionsByID[id], !session.isArchived,
              session.savedAgentProfileID == profileID, session.belongsToWorkspace(workspace),
              !session.isAgentEventChat, session.agentTriggerID?.nilIfEmpty == nil,
              app?.agentCrewChat.boundProfileID(for: id) == nil else {
            invalidateSelection()
            error = "This conversation is no longer available for your companion in this project."
            return
        }
    }

    private func invalidateSelection() {
        selectionRevision = UUID()
        loadTask?.cancel()
        loadTask = nil
        selectedSessionID = nil
        loadedSessionID = nil
        isLoading = false
        error = nil
    }
}

private struct CompanionPanelConversation: Decodable {
    let detail: SessionDetailResponse
    let identity: AgentCrewChatSessionIdentity
    init(from decoder: Decoder) throws {
        detail = try SessionDetailResponse(from: decoder)
        identity = try AgentCrewChatSessionIdentity(from: decoder)
    }
}
