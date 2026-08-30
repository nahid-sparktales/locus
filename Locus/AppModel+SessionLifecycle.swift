import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Session lifecycle: clear-chat flows, new local and worktree sessions,
/// resume with its transcript load, and foreground worker switching.
extension AppModel {
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
    func armSessionResetWatchdog() {
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
        startNewChat(in: workspacePath, environment: nil)
    }

    func newSession(in workspacePath: String) {
        startNewChat(in: workspacePath, environment: nil)
    }

    func newSession(in workspacePath: String, environment: ChatExecutionEnvironment) {
        startNewChat(in: workspacePath, environment: environment, baseRef: "HEAD")
    }

    func newWorktreeSession(in workspacePath: String, baseRef: String) {
        startNewChat(in: workspacePath, environment: .worktree, baseRef: baseRef)
    }

    func openWorkspace(_ group: WorkspaceChatGroup) {
        setWorkspaceExpanded(group.id, expanded: true)
        if let latest = group.chats.max(by: { $0.mtime < $1.mtime }) {
            resume(latest)
        } else if let path = group.path {
            startNewChat(in: path, environment: nil)
        }
    }

    func startNewChat(
        in rawPath: String,
        environment requestedEnvironment: ChatExecutionEnvironment?,
        baseRef: String = "HEAD"
    ) {
        activity.activityCenterPresented = false
        guard !pendingSessionReset else {
            showToast("Wait for the current chat change to finish")
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
                let isGit = (try? await GitClient(workspaceRoot: path).run(
                    ["rev-parse", "--show-toplevel"]
                )) != nil
                let environment = requestedEnvironment
                    ?? (settings.newGitChatsUseWorktree && isGit ? .worktree : .local)
                let response = try await backend.post(
                    "/api/sessions/new",
                    body: [
                        "reason": "workspace_chat",
                        "cwd": path,
                        "environment": environment.rawValue,
                        "base_ref": baseRef,
                        "worktree_retention_limit": settings.worktreeRetentionLimit,
                    ],
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
                reconcileChatSplitRestoration()
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
        activity.activityCenterPresented = false
        let currentIsBackgroundCapable = taskWorkers[currentSessionID] != nil
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
        prepareSplitSelection(session.id)
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
                clearPendingQuestion()
                queuedMessages = []
                restoredTranscriptContext = nil
                // Pre-acknowledge the session's workspace so a later
                // session_info event doesn't wipe the freshly loaded transcript.
                appliedWorkspacePath = response.sessionInfo.cwd
                pendingWorkspacePath = nil
                blocks = ChatTranscriptBuilder.blocks(from: response.messages)
                splitPaneBlocks[response.sessionInfo.sessionID] = blocks
                paneState(containing: response.sessionInfo.sessionID)?.blocks = blocks
                if let error = taskConversationStates[response.sessionInfo.sessionID]?
                    .errorMessage?.nilIfEmpty,
                   blocks.last?.text != error {
                    blocks.append(ChatBlock(kind: .error, text: error))
                }
                refreshAnchoredRunsIfNeeded()
                applyPendingSearchHitIfNeeded()
                sessionInfo = response.sessionInfo
                currentSessionID = response.sessionInfo.sessionID
                sendComputerControlCapability()
                sendSimulatorControlCapability()
                dispatcherActivity = nil
                dispatcherValidationReason = nil
                teamRunLive.restoreActivities(response.agentActivities)
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
                        updatedAt: Date(),
                        errorMessage: taskConversationStates[
                            response.sessionInfo.sessionID
                        ]?.errorMessage
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
        guard let runtime = taskWorkers[currentSessionID] else { return }
        runtime.queuedMessages = queuedMessages
        // A question belongs to its chat: park it on the runtime so it comes
        // back when this chat does, and never fronts another session — an
        // answer sent there would start a turn in the wrong conversation.
        if let captured = capturedQuestionThisTurn { runtime.capturedQuestion = captured }
        if let pending = pendingUserQuestion { runtime.pendingQuestion = pending }
        clearPendingQuestion()
        computerControl.cancelPendingActions()
        // No browser cancellation here, at any scope: the worker keeps running
        // in the background and its browser actions are served on its own
        // socket regardless of which conversation is in front — cancelling
        // would kill an action that is still going to be answered.
        flushPendingTokens()
        finalizeStreamingBlocks()
        runtime.streamingBlockID = streamingAssistantID
        if let streamingAssistantID,
           let block = blocks.first(where: { $0.id == streamingAssistantID }) {
            runtime.streamingText = block.text
            runtime.streamingReasoning = block.reasoningText ?? ""
        }
        streamingAssistantID = nil
        streamingReply.resetTurn()
        isBusy = false
        orchestrationState = nil
        dispatcherActivity = nil
        dispatcherValidationReason = nil
        teamRunLive.restoreActivities([])
        activeTaskRecord = nil
        taskHasChanges = false
        taskPatchBytes = 0
    }

    private func activateWorkerSession(_ session: SessionSummary, runtime: ChatWorkerRuntime) {
        flushPendingTokens()
        finalizeStreamingBlocks()
        streamingAssistantID = nil
        streamingReply.resetTurn()
        // The previous session's question must not front this one; this
        // session's own parked question is restored below.
        clearPendingQuestion()
        currentSessionID = runtime.sessionID
        sendComputerControlCapability(to: runtime.service, sessionID: runtime.sessionID)
        sendSimulatorControlCapability(to: runtime.service, sessionID: runtime.sessionID)
        queuedMessages = runtime.queuedMessages
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
                blocks = ChatTranscriptBuilder.blocks(from: detail.messages)
                splitPaneBlocks[runtime.sessionID] = blocks
                paneState(containing: runtime.sessionID)?.blocks = blocks
                if let streamingID = runtime.streamingBlockID {
                    blocks.append(ChatBlock(
                        id: streamingID,
                        kind: .assistant,
                        text: runtime.streamingText,
                        reasoningText: runtime.streamingReasoning.nilIfEmpty,
                        isStreaming: true
                    ))
                    streamingAssistantID = streamingID
                }
                refreshAnchoredRunsIfNeeded()
                teamRunLive.restoreActivities(detail.agentActivities ?? [])
                orchestrationState = detail.orchestrationState
                    ?? taskConversationStates[runtime.sessionID]?.state
                    ?? detail.task?.state
                orchestrationRunID = detail.orchestrationRunID
                    ?? taskConversationStates[runtime.sessionID]?.runID
                activeWorkerID = detail.workerID
                activeTaskRecord = detail.task ?? runtime.sessionInfo?.task
                let activeStates: Set<TeamRunState> = [
                    .queued, .dispatching, .running, .waitingPermission,
                    .waitingComputer, .waitingDispatchApproval, .reviewing,
                ]
                isBusy = orchestrationState.map(activeStates.contains)
                    ?? runtime.occupiesExecutionSlot
                turnStartedAt = runtime.startedAt
                turnDispatchedMode = runtime.dispatchedMode
                turnDispatchedTeamRunID = runtime.dispatchedTeamRunID
                turnDispatchedInPlanMode = runtime.dispatchedInPlanMode
                if let captured = runtime.capturedQuestion {
                    runtime.capturedQuestion = nil
                    capturedQuestionThisTurn = captured
                }
                if let question = runtime.pendingQuestion {
                    runtime.pendingQuestion = nil
                    pendingUserQuestion = question
                }
                if let pending = runtime.pendingForegroundEvent {
                    runtime.pendingForegroundEvent = nil
                    handle(pending)
                }
                if let error = runtime.lastError?.nilIfEmpty,
                   blocks.last?.text != error {
                    blocks.append(ChatBlock(kind: .error, text: error))
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
}
