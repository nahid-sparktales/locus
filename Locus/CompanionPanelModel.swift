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
    @Published private(set) var isClearing = false
    @Published private var sendingSessionIDs: Set<String> = []
    @Published var error: String?
    let mode: WorkMode = .ask

    private weak var app: AppModel?
    private var selectionRevision = UUID()
    private var loadedSessionID: String?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var creationTask: Task<Void, Never>?
    private(set) var clearingTask: Task<Void, Never>?
    private var sendingTasks: [String: Task<Void, Never>] = [:]
    private var catalogObservation: AnyCancellable?
    private var transcriptObservation: AnyCancellable?
    private var paneDraftObservation: AnyCancellable?
    private var dispatch: ((Submission, SavedAgentConversationMetadata) async throws -> Void)?
    @Published private var pendingMessages: [String: [ChatBlock]] = [:]
    private var draftRevisions: [String: UInt64] = [:]

    private struct Submission {
        let sessionID: String
        let workspace: String
        let profileID: UUID
        let text: String
        let mode: WorkMode
        let attachments: [ChatAttachment]
        let runID: String
    }

    func configure(app: AppModel,
                   dispatch: ((String, String, UUID, String, WorkMode, [ChatAttachment]) async throws -> Void)? = nil) {
        self.app = app
        self.dispatch = { [weak app] submission, validatedSession in
            if let dispatch {
                try await dispatch(submission.sessionID, submission.workspace, submission.profileID,
                                   submission.text, submission.mode, submission.attachments)
            } else {
                guard let app else { throw CancellationError() }
                try await app.sendSavedAgentTurn(sessionID: submission.sessionID, workspace: submission.workspace,
                    profileID: submission.profileID, text: submission.text, mode: submission.mode,
                    runID: submission.runID, preservingForeground: true, attachments: submission.attachments,
                    validatedSession: validatedSession)
            }
        }
        // Catalog changes intentionally do not invalidate the entire AppModel.
        // Observe this store only for the panel's history and selected identity.
        catalogObservation = app.sessionCatalog.$snapshot.dropFirst().sink { [weak self] snapshot in
            self?.catalogDidChange(snapshot)
        }
        transcriptObservation = app.$splitPaneBlocks.sink { [weak self] transcripts in
            self?.reconcilePendingMessages(with: transcripts)
        }
        paneDraftObservation = app.$splitPaneDrafts.dropFirst().sink { [weak self, weak app] drafts in
            guard let self, let app else { return }
            // Observe the canonical store so edits from a split pane or voice
            // are protected just like edits through the inspector's binding.
            // @Published supplies the next dictionary before its backing value.
            for id in sendingSessionIDs where (drafts[id] ?? "") != (app.splitPaneDrafts[id] ?? "") {
                draftRevisions[id, default: 0] &+= 1
            }
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
        var visible = app?.paneBlocks(for: id) ?? []
        guard let candidates = pendingMessages[id], !candidates.isEmpty else { return visible }
        let durableRunIDs = Set(visible.lazy.filter { $0.kind == .user }.compactMap(\.runID))
        let pending = candidates.filter { !durableRunIDs.contains($0.runID ?? "") }
        if !pending.isEmpty {
            // Keep submitted text visible while admission or the first
            // authoritative transcript refresh is still in flight.
            let insertion = visible.firstIndex(where: \.isStreaming) ?? visible.endIndex
            visible.insert(contentsOf: pending, at: insertion)
        }
        return visible
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
        if isForegroundConversation { return "This conversation is open in the center. Continue chatting there." }
        guard app.isAgentOnline else { return "Your companion is ready. Reconnect Locus to continue." }
        let effectiveProfile = selectedSessionID.map { app.agentChatProfile(profile, sessionID: $0) } ?? profile
        do { _ = try app.agentProfileProvider(effectiveProfile); return nil }
        catch { return error.localizedDescription }
    }
    var canSend: Bool {
        selectionIsCurrent && selectedSessionID != nil && loadedSessionID == selectedSessionID && !isLoading && !isSending
            && !isCreating && !isClearing && !state.busy && availabilityIssue == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(app?.companionContext.attachments.isEmpty ?? true))
    }
    var canRetryLoading: Bool {
        selectionIsCurrent && selectedSessionID != nil && loadedSessionID != selectedSessionID
            && !isLoading && app?.isAgentOnline == true
    }
    /// Read receipts require the current owner's successfully loaded transcript.
    /// A selected ID alone may still be opening, offline, or have failed validation.
    var hasLoadedConversation: Bool {
        selectionIsCurrent && selectedSessionID != nil && loadedSessionID == selectedSessionID
            && !isLoading && !isCreating && !isClearing
    }
    private var scopeIsCurrent: Bool {
        guard let app, profile != nil else { return false }
        return profileID == app.agentTeamsModel.primaryCompanionID && workspace == app.companionWorkspacePath
    }
    private var selectionIsCurrent: Bool {
        scopeIsCurrent && chats.contains { $0.id == selectedSessionID }
    }

    /// The inspector reads the same companion conversation as the center.
    func activate() {
        guard let app else { return }
        app.companionContext.activate(app.companionScope)
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
        let candidates = chats
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
        app.rememberCompanionPanelSession(session.id, workspace: workspace)
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
                app.rememberCompanionPanelSession(session.id, workspace: requestedWorkspace, profileID: profileID)
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
        guard let app, let profile, scopeIsCurrent, !isCreating, !isClearing else { return }
        if let existing = app.companionConversation {
            select(existing)
            return
        }
        guard app.creatingSavedAgentChatIDs.insert(profile.id).inserted else { return }
        guard app.isAgentOnline else {
            app.creatingSavedAgentChatIDs.remove(profile.id)
            error = "Reconnect Locus before opening a new conversation."
            return
        }
        let requestedWorkspace = workspace
        let revision = selectionRevision
        isCreating = true
        error = nil
        creationTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer {
                isCreating = false
                creationTask = nil
                app.creatingSavedAgentChatIDs.remove(profile.id)
            }
            do {
                let session = try await app.createSavedAgentConversation(profile, workspace: requestedWorkspace,
                                                                         preservingForeground: true)
                app.rememberCompanionPanelSession(session.id, workspace: requestedWorkspace, profileID: profile.id)
                guard selectionRevision == revision, profileID == profile.id else { return }
                activate()
            } catch {
                guard selectionRevision == revision, scopeIsCurrent else { return }
                self.error = error.localizedDescription
            }
        }
    }

    var canClearConversation: Bool {
        guard let app, selectionIsCurrent, let id = selectedSessionID else { return false }
        return app.isAgentOnline && !isCreating && !isClearing && !isSending && !state.busy
            && !app.pendingSessionReset && app.goals.goal(for: id)?.status != .active
    }

    /// Start empty only after the replacement is durable. The former transcript
    /// is archived through the normal API and remains recoverable in history.
    func clearConversation() {
        activate()
        guard canClearConversation, let app, let profile,
              let previous = app.companionConversation else { return }
        guard app.creatingSavedAgentChatIDs.insert(profile.id).inserted else { return }
        let requestedWorkspace = app.savedAgentWorkspacePath(profile)
        let previousWorkspace = workspace
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        let wasForeground = previous.id == app.currentSessionID
        isClearing = true
        error = nil
        clearingTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer {
                isClearing = false
                clearingTask = nil
                app.creatingSavedAgentChatIDs.remove(profile.id)
            }
            do {
                let response = try await app.backend.get("/api/sessions/\(previous.id)", as: CompanionPanelConversation.self)
                guard response.identity.matches(sessionID: previous.id, profileID: profile.id, workspace: previousWorkspace),
                      response.detail.archived != true, app.primaryCompanionProfile?.id == profile.id,
                      app.companionConversation?.id == previous.id,
                      !app.savedAgentConversationState(previous.id).busy,
                      app.goals.goal(for: previous.id)?.status != .active else {
                    throw SavedAgentConversationError.unavailable("This companion conversation cannot be cleared right now.")
                }
                let replacement = try await app.createSavedAgentConversation(profile, workspace: requestedWorkspace,
                                                                             preservingForeground: true)
                // A turn or approval may have arrived while creation was in flight.
                // Leave the original selected if it can no longer safely clear.
                guard app.primaryCompanionProfile?.id == profile.id,
                      !app.savedAgentConversationState(previous.id).busy,
                      app.goals.goal(for: previous.id)?.status != .active else {
                    throw SavedAgentConversationError.unavailable("Wait for your companion to finish before clearing the chat.")
                }
                app.rememberCompanionPanelSession(replacement.id, workspace: requestedWorkspace, profileID: profile.id)
                if wasForeground, app.transcriptPresentation.sessionOwnershipToken == ownership,
                   app.canSwitchToCompanionChat {
                    app.resume(replacement, destination: .agents)
                    await app.activeTranscriptLoad?.task.value
                }
                activate()
                guard previous.id != app.currentSessionID else {
                    throw SavedAgentConversationError.unavailable("Your fresh companion chat is ready. Open it before archiving the previous conversation.")
                }
                guard !app.savedAgentConversationState(previous.id).busy,
                      app.goals.goal(for: previous.id)?.status != .active else {
                    throw SavedAgentConversationError.unavailable("Your previous conversation is still working and was kept in history.")
                }
                _ = try await app.backend.patch("/api/sessions/\(previous.id)", body: ["archived": true],
                                                as: SessionMetadataResponse.self)
                try await app.refreshCompanionConversationCatalog()
                app.showToast("Companion chat cleared")
            } catch {
                self.error = error.localizedDescription
                app.showToast("Could not finish clearing the companion chat: \(error.localizedDescription)")
            }
        }
    }

    func send() {
        guard canSend, let app, let id = selectedSessionID, let profileID, let dispatch else { return }
        let scope = CompanionConversationScope(sessionID: id, workspace: workspace, profileID: profileID)
        let attachments = app.companionContext.scope == scope ? app.companionContext.attachments : []
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Please look at the shared context."
        let originalDraft = draft
        let requestedWorkspace = workspace
        let revision = selectionRevision
        let submission = Submission(sessionID: id, workspace: requestedWorkspace, profileID: profileID,
                                    text: text, mode: mode, attachments: attachments, runID: UUID().uuidString)
        sendingSessionIDs.insert(id)
        error = nil
        // Acknowledge the click synchronously. Network validation and queue
        // admission must never hold submitted text in the composer for seconds.
        let durableRunIDs = Set(app.paneBlocks(for: id).lazy.filter { $0.kind == .user }.compactMap(\.runID))
        pendingMessages[id] = (pendingMessages[id] ?? []).filter { !durableRunIDs.contains($0.runID ?? "") }
            + [ChatBlock(kind: .user, text: text, runID: submission.runID)]
        app.setPaneDraft("", for: id)
        let draftRevision = draftRevisions[id, default: 0]
        let foregroundDraftRevision = app.composerState.draftRevision
        sendingTasks[id] = Task { [weak self, weak app] in
            guard let self, let app else { return }
            defer { sendingSessionIDs.remove(id); sendingTasks[id] = nil }
            do {
                // Fetch only routing metadata, once. The runtime uses this same
                // durable ownership check instead of reading the transcript again.
                let response = try await app.backend.get("/api/sessions/\(id)/execution-context",
                                                         as: SavedAgentConversationMetadata.self)
                try Task.checkCancellation()
                guard selectionRevision == revision, scopeIsCurrent, selectedSessionID == id,
                      id != app.currentSessionID else { throw CancellationError() }
                guard response.matches(sessionID: id, profileID: profileID, workspace: requestedWorkspace) else {
                    throw SavedAgentConversationError.unavailable("This conversation no longer belongs to your companion and project, or is archived.")
                }
                try await dispatch(submission, response)
                app.companionContext.consume(Set(attachments.map(\.id)), for: scope)
            } catch {
                // Restore only an untouched composer. A later edit, including
                // an intentional edit back to empty, belongs to the user.
                let foregroundIsUntouched = id != app.currentSessionID
                    || app.composerState.draftRevision == foregroundDraftRevision
                let canRestoreDraft = draftRevisions[id, default: 0] == draftRevision
                    && foregroundIsUntouched && app.paneDraft(for: id).isEmpty
                if canRestoreDraft {
                    app.setPaneDraft(originalDraft, for: id)
                    pendingMessages[id]?.removeAll { $0.runID == submission.runID }
                    if pendingMessages[id]?.isEmpty == true { pendingMessages[id] = nil }
                } else {
                    // Keep both drafts recoverable. The main composer already
                    // retains failed submitted rows; do the same here, with an
                    // explicit failure label even when cancellation is silent.
                    let failed = ChatBlock(kind: .error,
                        text: "Message not sent. Copy the message above to retry.", runID: submission.runID)
                    if id == app.currentSessionID {
                        if !app.blocks.contains(where: { $0.kind == .user && $0.runID == submission.runID }) {
                            app.blocks.append(ChatBlock(kind: .user, text: text, runID: submission.runID))
                        }
                        app.blocks.append(failed)
                        pendingMessages[id]?.removeAll { $0.runID == submission.runID }
                        if pendingMessages[id]?.isEmpty == true { pendingMessages[id] = nil }
                    } else {
                        pendingMessages[id, default: []].append(failed)
                    }
                    app.showToast("Companion message not sent — your newer draft is unchanged.")
                }
                guard selectionRevision == revision, scopeIsCurrent else { return }
                if !canRestoreDraft {
                    self.error = "Message not sent. Your draft is unchanged; copy the earlier message to retry."
                } else if !Task.isCancelled && !(error is CancellationError) {
                    self.error = error.localizedDescription
                }
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
              chats.contains(where: { $0.id == id }) else { return }
        guard app.isAgentOnline, app.canSwitchToCompanionChat else {
            error = "Finish or stop the active foreground run before opening this conversation."
            return
        }
        app.openCompanionMainConversation()
    }

    private func reconcilePendingMessages(with transcripts: [String: [ChatBlock]]) {
        for (id, pending) in pendingMessages {
            guard let transcript = transcripts[id] else { continue }
            let durableRunIDs = Set(transcript.lazy.filter { $0.kind == .user }.compactMap(\.runID))
            let remaining = pending.filter { !durableRunIDs.contains($0.runID ?? "") }
            if remaining.count != pending.count { pendingMessages[id] = remaining.isEmpty ? nil : remaining }
        }
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
