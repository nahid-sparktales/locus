import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The chat turn pipeline: send with its admission queue and dispatch
/// snapshotting, steering, queuing, regeneration, stop, and the quit-time
/// running-work drain.
extension AppModel {
    func send(_ rawText: String) {
        send(rawText, preservingDraftOnFailure: true)
    }

    func send(
        _ rawText: String,
        preservingDraftOnFailure: Bool,
        requeueingOnFailure: Bool = false,
        includeAttachments: Bool = true,
        automaticRoutingPrepared: Bool = false,
        preparedModelRoute: ModelRoutingPreparedTurn? = nil
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableAttachments = includeAttachments ? availableChatAttachments : []
        let hasChatAttachments = !availableAttachments.isEmpty
        guard !text.isEmpty || hasChatAttachments else { return }

        // Slash commands that Locus can run itself execute immediately, even
        // mid-run; anything else starting with "/" goes to the agent verbatim.
        if !text.isEmpty, let command = SlashCommand.command(invokedBy: text) {
            if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draftText = ""
            }
            recordPrompt(text)
            execute(command, argument: SlashCommand.argument(in: text))
            return
        }

        if isBusy || hasPendingPermission {
            if hasChatAttachments {
                showToast("Wait for the current reply before sending attachments")
                return
            }
            queuedMessages.append(text)
            taskWorkers[currentSessionID]?.queuedMessages = queuedMessages
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
        guard isAgentOnline else {
            stashUnsent(text, requeue: requeueingOnFailure, preserveDraft: preservingDraftOnFailure)
            return
        }

        let isSlashPassthrough = SlashCommand.query(from: text) != nil
        // Capture the mode before any asynchronous context work. A user can
        // change the picker while that work is pending; the dispatched turn
        // must keep the safety contract it started with.
        let dispatchedMode = selectedMode
        let teamMention = TeamMentionResolver.selection(
            in: text,
            profiles: agentProfiles,
            teams: agentTeams
        )
        let wantsTeam = dispatchedMode != .ask
            && !isSlashPassthrough
            && (selectedAgentTeamID != nil || teamMention.agent != nil || teamMention.team != nil)
        let dispatchedTeam = wantsTeam ? teamManifest(for: text) : nil
        if wantsTeam, dispatchedTeam == nil { return }
        let dispatchedSoloSwarm = dispatchedTeam == nil
            && selectedAgentTeamID == nil
            && dispatchedMode != .ask
            && !isSlashPassthrough
        if settings.automaticModelRoutingEnabled,
           !automaticRoutingPrepared,
           !isSlashPassthrough,
           dispatchedTeam == nil
        {
            isBusy = true
            modelRouterMessage = "Choosing a model for this message…"
            let requiresVision = availableAttachments.contains {
                $0.kind == .image || $0.kind == .applicationSnapshot
            }
            Task { [weak self] in
                guard let self else { return }
                let route = await prepareAutomaticModelRoute(
                    text: text,
                    mode: dispatchedMode,
                    requiresVision: requiresVision
                )
                isBusy = false
                send(
                    rawText,
                    preservingDraftOnFailure: preservingDraftOnFailure,
                    requeueingOnFailure: requeueingOnFailure,
                    includeAttachments: includeAttachments,
                    automaticRoutingPrepared: true,
                    preparedModelRoute: route
                )
            }
            return
        }
        // Agent-side slash commands never receive attachments (the server
        // routes them past the turn machinery), so dispatching any would
        // silently drop them — keep the chips for the next real message.
        let dispatchedAttachments = isSlashPassthrough && dispatchedMode != .ask
            ? [] : availableAttachments
        let messageText = text.isEmpty ? "Please analyze the attached files." : text
        let dispatchedSessionID = currentSessionID
        let dispatchedWorkspaceRoot = workspacePath
        let dispatchedExecutionPath = activeTaskRecord?.executionPath ?? dispatchedWorkspaceRoot
        let dispatchedEnvironment = currentExecutionEnvironment
        let dispatchedContextFiles = contextFiles
        let dispatchedLiveApplication = dispatchedMode == .ask ? nil
            : liveApplicationTargets[dispatchedSessionID].flatMap {
                applicationContext.isConnected($0) ? $0 : nil
            }
        let dispatchedSimulator = dispatchedMode == .ask
            ? nil : simulatorControl.target(for: dispatchedSessionID)
        let dispatchedRestoredContext = isSlashPassthrough ? nil : restoredTranscriptContext
        if !isSlashPassthrough { restoredTranscriptContext = nil }

        isBusy = true
        turnStartedAt = Date()
        automaticModelRoutingTurns[dispatchedSessionID] = preparedModelRoute
        planApprovalPending = false
        planTodosChangedThisTurn = false
        planReadyThisTurn = false
        clearPendingQuestion()
        // Agent-side slash commands (/init and friends) may write todos, but
        // running one is housekeeping, never a plan worth offering to build.
        turnDispatchedInPlanMode = dispatchedMode == .plan && !isSlashPassthrough
        turnDispatchedMode = isSlashPassthrough ? nil : dispatchedMode
        turnDispatchedTeamRunID = dispatchedTeam?["run_id"] as? String
        let oneMessageSnapshotIDs = Self.attachmentIDsToClear(
            dispatchedAttachments,
            deliverySucceeded: true
        ).subtracting(
            Self.attachmentIDsToClear(dispatchedAttachments, deliverySucceeded: false)
        )
        if !dispatchedAttachments.isEmpty {
            let sentIDs = Self.attachmentIDsToClear(
                dispatchedAttachments,
                deliverySucceeded: false
            )
            chatAttachments.removeAll { sentIDs.contains($0.id) }
            chatAttachmentNotice = nil
        }
        let attachmentLine = dispatchedAttachments.isEmpty
            ? nil
            : "Attached: \(dispatchedAttachments.map(\.name).joined(separator: ", "))"
        let visibleText = [text.nilIfEmpty, attachmentLine]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let teamRunID = (dispatchedTeam?["run_id"] as? String)?.nilIfEmpty
        let reservedRunID = teamRunID ?? UUID().uuidString
        let visibleBlock = ChatBlock(kind: .user, text: visibleText, runID: reservedRunID)
        blocks.append(visibleBlock)
        if let info = sessionInfo, sessionOverview.activeSessionID != info.sessionID {
            activateSessionOverview(info)
        }
        sessionOverview.emit(.message(role: .user, at: Self.sessionTimestamp))
        sessionOverview.emit(.status(
            status: .running,
            reason: nil,
            at: Self.sessionTimestamp
        ))
        beginSessionFileCapture()
        // Agent-side slash commands go out as raw text: no context pack, so
        // none of it counts as provided.
        let providedItems = Self.providedSourceItems(
            attachments: dispatchedAttachments,
            contextFiles: isSlashPassthrough ? [] : dispatchedContextFiles,
            mode: dispatchedMode,
            liveApplication: dispatchedLiveApplication,
            simulator: dispatchedSimulator
        )
        if !providedItems.isEmpty {
            sessionOverview.emit(.sourceProvided(items: providedItems, at: Self.sessionTimestamp))
        }
        if !text.isEmpty { recordPrompt(text) }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        // Adaptive workers stay inside the ordinary Solo experience. The Runs
        // inspector still opens automatically for explicit teams only.
        let opensRuns = dispatchedTeam != nil
        presentInspectorForSentRequest(
            isTeam: opensRuns,
            runID: opensRuns ? reservedRunID : nil
        )
        let previousRuntimeState = taskConversationStates[dispatchedSessionID]
        taskConversationStates[dispatchedSessionID] = TaskConversationState(
            sessionID: dispatchedSessionID,
            taskID: activeTaskRecord?.id ?? previousRuntimeState?.taskID,
            teamID: previousRuntimeState?.teamID,
            workerID: previousRuntimeState?.workerID,
            runID: reservedRunID,
            state: .queued,
            updatedAt: Date()
        )

        let pendingTurnToken = UUID()
        let pendingTurn = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pendingChatTurnTokens[dispatchedSessionID] == pendingTurnToken {
                    self.pendingChatTurns.removeValue(forKey: dispatchedSessionID)
                    self.pendingChatTurnTokens.removeValue(forKey: dispatchedSessionID)
                }
            }
            guard !Task.isCancelled else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                return
            }
            do {
                let queuedTeam = dispatchedTeam?["team"] as? [String: Any]
                let _: OrchestrationRun = try await self.backend.post(
                    "/api/runs/queue",
                    body: [
                        "run_id": reservedRunID,
                        "session_id": dispatchedSessionID,
                        "message_id": visibleBlock.id.uuidString,
                        "workspace_root": dispatchedWorkspaceRoot,
                        "execution_path": dispatchedExecutionPath,
                        "request": messageText,
                        "run_kind": dispatchedTeam == nil ? "solo" : "team",
                        "team_id": queuedTeam?["id"] as? String ?? "",
                        "team_name": queuedTeam?["name"] as? String ?? "",
                        "execution_environment": dispatchedEnvironment.rawValue,
                        "solo_swarm": dispatchedSoloSwarm,
                    ],
                    as: OrchestrationRun.self
                )
            } catch {
                if let previousRuntimeState {
                    self.taskConversationStates[dispatchedSessionID] = previousRuntimeState
                } else {
                    self.taskConversationStates.removeValue(forKey: dispatchedSessionID)
                }
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                if self.currentSessionID == dispatchedSessionID {
                    self.isBusy = false
                    self.turnStartedAt = nil
                    self.turnDispatchedMode = nil
                    self.turnDispatchedTeamRunID = nil
                    self.turnDispatchedInPlanMode = false
                    self.stashUnsent(
                        text,
                        requeue: requeueingOnFailure,
                        preserveDraft: preservingDraftOnFailure
                    )
                } else if requeueingOnFailure,
                          let runtime = self.taskWorkers[dispatchedSessionID] {
                    runtime.queuedMessages.insert(text, at: 0)
                }
                self.showToast("Could not queue this chat: \(error.localizedDescription)")
                return
            }
            let refreshedContextFiles = dispatchedMode == .ask || dispatchedContextFiles.isEmpty
                ? dispatchedContextFiles
                : await Task.detached(priority: .utility) {
                    dispatchedContextFiles.map(ContextPackLoader.reloadContextReference)
                }.value
            guard !Task.isCancelled else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                return
            }
            let payload = isSlashPassthrough
                ? text
                : Self.decoratedPrompt(
                    messageText,
                    mode: dispatchedMode,
                    chatAttachments: dispatchedAttachments,
                    contextFiles: refreshedContextFiles,
                    restoredTranscriptContext: dispatchedRestoredContext,
                    liveApplication: dispatchedLiveApplication,
                    simulator: dispatchedSimulator
                )
            var request: [String: Any] = [
                "type": "user_message",
                "text": payload,
                "mode": dispatchedMode.rawValue,
            ]
            if let agentConfig = encodedJSONObject(self.primaryAgentBehavior) {
                request["agent_config"] = agentConfig
            }
            if let dispatchedTeam { request["team"] = dispatchedTeam }
            if dispatchedTeam == nil { request["run_id"] = reservedRunID }
            if dispatchedSoloSwarm {
                request["solo_swarm"] = ["enabled": true]
            }
            let imageAttachments: [[String: Any]] = dispatchedAttachments.compactMap {
                attachment in
                guard attachment.kind == .image || attachment.kind == .applicationSnapshot,
                      let data = attachment.imageData,
                      let mimeType = attachment.mimeType
                else { return nil }
                return [
                    "name": attachment.name,
                    "mime_type": mimeType,
                    "data": data.base64EncodedString(),
                ]
            }
            if !imageAttachments.isEmpty { request["attachments"] = imageAttachments }
            guard let worker = await self.ensureChatWorker(
                for: dispatchedSessionID,
                workspaceRoot: dispatchedWorkspaceRoot
            ) else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                if Task.isCancelled { return }
                if self.currentSessionID == dispatchedSessionID {
                    self.isBusy = false
                    self.turnStartedAt = nil
                    self.turnDispatchedMode = nil
                    self.turnDispatchedTeamRunID = nil
                    self.turnDispatchedInPlanMode = false
                    self.stashUnsent(
                        text,
                        requeue: requeueingOnFailure,
                        preserveDraft: preservingDraftOnFailure
                    )
                }
                return
            }
            guard !Task.isCancelled else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                self.finishChatRuntime(worker, state: .cancelled)
                return
            }
            worker.dispatchedMode = isSlashPassthrough ? nil : dispatchedMode
            worker.dispatchedTeamRunID = teamRunID
            worker.reservedRunID = reservedRunID
            worker.dispatchedInPlanMode = dispatchedMode == .plan && !isSlashPassthrough
            guard await self.waitForChatExecutionSlot(worker) else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                return
            }
            do {
                let _: OrchestrationRun = try await self.backend.patch(
                    "/api/runs/\(reservedRunID)/queue",
                    body: ["action": "admit"],
                    as: OrchestrationRun.self
                )
            } catch {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                self.finishChatRuntime(worker, state: .failed, error: "The queued run could not start")
                return
            }
            guard worker.service.send(request) else {
                self.discardAutomaticModelRoutingTurn(
                    for: dispatchedSessionID,
                    matching: preparedModelRoute
                )
                self.finishChatRuntime(worker, state: .failed, error: "The turn could not be delivered")
                if self.currentSessionID == dispatchedSessionID {
                    self.isBusy = false
                    self.turnStartedAt = nil
                    self.turnDispatchedMode = nil
                    self.turnDispatchedTeamRunID = nil
                    self.turnDispatchedInPlanMode = false
                    self.stashUnsent(
                        text,
                        requeue: requeueingOnFailure,
                        preserveDraft: preservingDraftOnFailure
                    )
                }
                return
            }
            // Appshots are explicit one-message captures. Retain them through
            // queue and transport failures; clear only after accepted delivery.
            if self.currentSessionID == dispatchedSessionID, !oneMessageSnapshotIDs.isEmpty {
                self.chatAttachments.removeAll { oneMessageSnapshotIDs.contains($0.id) }
                if self.chatAttachments.isEmpty { self.chatAttachmentNotice = nil }
            }
            worker.executionState = dispatchedTeam == nil ? .running : .dispatching
            worker.startedAt = Date()
            self.updateBackgroundChatState(worker)
        }
        pendingChatTurnTokens[dispatchedSessionID] = pendingTurnToken
        pendingChatTurns[dispatchedSessionID] = pendingTurn
    }

    func waitForChatExecutionSlot(_ runtime: ChatWorkerRuntime) async -> Bool {
        runtime.executionState = .queued
        runtime.startedAt = nil
        updateBackgroundChatState(runtime)
        chatAdmissionQueue.enqueue(runtime.sessionID)
        while runtime.process.isRunning {
            if Task.isCancelled {
                chatAdmissionQueue.remove(runtime.sessionID)
                return false
            }
            let occupied = taskWorkers.values.filter {
                $0 !== runtime && $0.occupiesExecutionSlot
            }.count
            if chatAdmissionQueue.isFirst(runtime.sessionID),
               occupied < AppSettings.clampMaximumActiveChats(settings.maximumActiveChats),
               !hasLocalWriterCollision(for: runtime) {
                chatAdmissionQueue.remove(runtime.sessionID)
                runtime.executionState = .running
                runtime.startedAt = Date()
                updateBackgroundChatState(runtime)
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled {
                chatAdmissionQueue.remove(runtime.sessionID)
                return false
            }
        }
        chatAdmissionQueue.remove(runtime.sessionID)
        return false
    }

    private func hasLocalWriterCollision(for runtime: ChatWorkerRuntime) -> Bool {
        guard runtime.dispatchedMode == .work || runtime.dispatchedMode == .grill,
              runtime.sessionInfo?.environment?["type"] != ChatExecutionEnvironment.worktree.rawValue,
              let root = runtime.sessionInfo?.environment?["canonical_repository"]
                ?? runtime.sessionInfo?.workspaceRoot ?? runtime.sessionInfo?.cwd
        else { return false }
        let canonical = URL(fileURLWithPath: root).standardizedFileURL.path
        return taskWorkers.values.contains { other in
            guard other !== runtime, other.occupiesExecutionSlot,
                  other.dispatchedMode == .work || other.dispatchedMode == .grill,
                  other.sessionInfo?.environment?["type"]
                    != ChatExecutionEnvironment.worktree.rawValue,
                  let otherRoot = other.sessionInfo?.environment?["canonical_repository"]
                    ?? other.sessionInfo?.workspaceRoot ?? other.sessionInfo?.cwd
            else { return false }
            return URL(fileURLWithPath: otherRoot).standardizedFileURL.path == canonical
        }
    }

    func updateBackgroundChatState(_ runtime: ChatWorkerRuntime) {  // internal(for: AppModel extension files)
        let previous = taskConversationStates[runtime.sessionID]
        taskConversationStates[runtime.sessionID] = TaskConversationState(
            sessionID: runtime.sessionID,
            taskID: runtime.sessionInfo?.task?.id ?? previous?.taskID,
            teamID: previous?.teamID,
            workerID: previous?.workerID,
            runID: previous?.runID,
            state: runtime.executionState,
            updatedAt: Date(),
            errorMessage: runtime.lastError ?? previous?.errorMessage
        )
    }

    func finishChatRuntime(
        _ runtime: ChatWorkerRuntime,
        state: TeamRunState,
        error: String? = nil
    ) {
        runtime.executionState = state
        runtime.startedAt = nil
        runtime.lastError = error
        runtime.dispatchedMode = nil
        runtime.dispatchedTeamRunID = nil
        runtime.dispatchedInPlanMode = false
        updateBackgroundChatState(runtime)
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
    func sendRaw(_ text: String) {
        if isBusy || hasPendingPermission {
            queuedMessages.append(text)
            showToast("Queued — sends when this turn finishes")
            return
        }
        guard isAgentOnline,
              conversationBackend.send(["type": "user_message", "text": text])
        else {
            showToast("Reconnect the local agent to run \(text)")
            return
        }
        isBusy = true
        turnStartedAt = Date()
        planApprovalPending = false
        planTodosChangedThisTurn = false
        clearPendingQuestion()
        turnDispatchedInPlanMode = false
        turnDispatchedMode = nil
        blocks.append(ChatBlock(kind: .user, text: text))
    }

    func submitDraft() {
        if isBusy {
            queueDraft()
        } else {
            send(draftText)
        }
    }

    /// Append the current direction to the active provider turn. The backend
    /// stops only the current generation, preserves completed tool results,
    /// and continues the same turn without an intermediate `turn_done`.
    func steerDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBusy,
              steeringState?.hasPrefix("Stopping") != true,
              !hasPendingPermission,
              !text.isEmpty
        else { return }
        guard conversationBackend.send(["type": "steer", "text": text]) else {
            showToast("Reconnect the local agent — the direction was not sent")
            return
        }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        steeringState = "Applying direction…"
        showToast("Steering the active turn")
    }

    /// Explicitly retain a message for the next independent turn.
    func queueDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queuedMessages.append(text)
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        showToast("Queued for the next turn")
    }

    /// Interrupt now, but do not start the replacement turn until the backend
    /// confirms the old one has fully unwound and persisted its terminal state.
    func stopAndSendDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBusy, !hasPendingPermission, !text.isEmpty else { return }
        guard conversationBackend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the active turn could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        cancelSimulatorActions(sessionID: currentSessionID)
        // Scoped: only this conversation is being stopped; a background
        // worker's in-flight page action keeps its real outcome.
        browser.cancelPendingActions(ownedBy: currentSessionID)
        pendingStopAndSend = text
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            draftText = ""
        }
        recordPrompt(text)
        steeringState = "Stopping before a new turn…"
        showToast("Stopping, then sending as a new turn")
    }

    func removeQueuedMessage(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
        taskWorkers[currentSessionID]?.queuedMessages = queuedMessages
    }

    func drainQueuedMessages() {
        guard !isBusy, !hasPendingPermission, !planApprovalPending,
              pendingUserQuestion == nil, !queuedMessages.isEmpty else {
            return
        }
        guard isAgentOnline else { return }
        // A queued message was composed before any attachments added while it
        // waited; those belong to the user's next explicit send.
        let message = queuedMessages.removeFirst()
        taskWorkers[currentSessionID]?.queuedMessages = queuedMessages
        send(
            message,
            preservingDraftOnFailure: false,
            requeueingOnFailure: true,
            includeAttachments: false
        )
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

    func resetHistoryCursorIfEdited() {
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

    /// Copies a completed assistant response from its authoritative source.
    /// Rendering never depends on the currently expanded portion of a code
    /// block or table, so a visually collapsed response still copies in full.
    func copyResponse(_ source: String, format: ResponseCopyFormat) {
        let text = ResponseCopyPayload.text(from: source, format: format)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied as \(format.title)")
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
        guard conversationBackend.send(["type": "retry_last"]) else {
            showToast("Reconnect the local agent before retrying")
            return
        }
        pendingRetry = true
        isBusy = true
        turnStartedAt = Date()
        planApprovalPending = false
        planTodosChangedThisTurn = false
        planReadyThisTurn = false
        clearPendingQuestion()
        turnDispatchedInPlanMode = selectedMode == .plan
        turnDispatchedMode = selectedMode
        sessionOverview.emit(.status(
            status: .running,
            reason: nil,
            at: Self.sessionTimestamp
        ))
        beginSessionFileCapture()
        showToast("Regenerating the last response")
    }

    func stop() {
        if let pendingTurn = pendingChatTurns[currentSessionID] {
            let queuedRunID = taskConversationStates[currentSessionID]?.runID
            pendingTurn.cancel()
            pendingChatTurns.removeValue(forKey: currentSessionID)
            pendingChatTurnTokens.removeValue(forKey: currentSessionID)
            chatAdmissionQueue.remove(currentSessionID)
            if let runtime = taskWorkers[currentSessionID] {
                finishChatRuntime(runtime, state: .cancelled)
            } else {
                let previous = taskConversationStates[currentSessionID]
                taskConversationStates[currentSessionID] = TaskConversationState(
                    sessionID: currentSessionID,
                    taskID: previous?.taskID,
                    teamID: previous?.teamID,
                    workerID: previous?.workerID,
                    runID: previous?.runID,
                    state: .cancelled,
                    updatedAt: Date()
                )
            }
            isBusy = false
            turnStartedAt = nil
            turnDispatchedMode = nil
            turnDispatchedTeamRunID = nil
            turnDispatchedInPlanMode = false
            showToast("Removed the queued run")
            if let queuedRunID {
                Task { [weak self] in
                    try? await self?.backend.patch(
                        "/api/runs/\(queuedRunID)/queue", body: ["action": "cancel"],
                        as: OrchestrationRun.self
                    )
                }
            }
            return
        }
        // If the interrupt cannot be delivered the run is still live on the
        // agent; leave the busy state to recoverFromLostConnection(), the one
        // place that reconciles cards and spinners after a drop.
        guard conversationBackend.send(["type": "interrupt"]) else {
            showToast("Reconnect the local agent — the run could not be stopped")
            return
        }
        computerControl.cancelPendingActions()
        cancelSimulatorActions(sessionID: currentSessionID)
        browser.cancelPendingActions(ownedBy: currentSessionID)
        pendingRetry = false
        steeringState = "Stopping the current run…"
        showToast("Stopping the current run")
    }

    var hasRunningWorkForQuit: Bool {
        !pendingChatTurns.isEmpty || terminal.hasForegroundJob || Self.shouldWarnBeforeQuit(
            isBusy: isBusy,
            hasPendingPermission: hasPendingPermission,
            currentSessionID: currentSessionID,
            orchestrationState: orchestrationState,
            taskConversationStates: taskConversationStates,
            liveWorkerSessionIDs: Set(
                taskWorkers.values.compactMap { runtime in
                    runtime.process.isRunning ? runtime.sessionID : nil
                }
            )
        )
    }

    /// A terminal durable run is authoritative for the current chat. Team
    /// workers intentionally remain alive between turns, so neither their
    /// process nor a stale pre-completion snapshot proves work is still active.
    static func shouldWarnBeforeQuit(
        isBusy: Bool,
        hasPendingPermission: Bool,
        currentSessionID: String,
        orchestrationState: TeamRunState?,
        taskConversationStates: [String: TaskConversationState],
        liveWorkerSessionIDs: Set<String>
    ) -> Bool {
        // These foreground flags are set synchronously when a new solo or team
        // turn begins, before a fresh orchestration event can replace the last
        // run's terminal state.
        if isBusy || hasPendingPermission {
            return true
        }
        if let orchestrationState, !orchestrationState.isTerminal {
            return true
        }
        let currentRunIsTerminal = orchestrationState?.isTerminal == true
        return taskConversationStates.contains { sessionID, snapshot in
            guard liveWorkerSessionIDs.contains(sessionID), !snapshot.state.isTerminal else {
                return false
            }
            // Completion events can arrive before older foreground flags and
            // task snapshots are cleared. Do not turn those stale values into
            // a destructive-looking quit confirmation.
            return sessionID != currentSessionID || !currentRunIsTerminal
        }
    }

    func stopRunningWorkForQuit(completion: @escaping @MainActor () -> Void) {
        terminal.terminate()
        for pendingTurn in pendingChatTurns.values { pendingTurn.cancel() }
        pendingChatTurns.removeAll()
        pendingChatTurnTokens.removeAll()
        chatAdmissionQueue = ChatAdmissionQueue()
        for runtime in taskWorkers.values {
            _ = runtime.service.send(["type": "interrupt"])
        }
        _ = backend.send(["type": "interrupt"])
        computerControl.cancelPendingActions()
        cancelSimulatorActions()
        simulatorControl.detachAll()
        browser.cancelPendingActions()
        guard hasRunningWorkForQuit else {
            completion()
            return
        }
        Task { @MainActor in
            // Give every worker a bounded window to append its interrupted
            // task state and terminal event before shutdown stops processes.
            for _ in 0..<20 {
                if !hasRunningWorkForQuit { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            completion()
        }
    }

    /// Security-sensitive services must be locked synchronously before either
    /// the updater or AppKit starts tearing down the rest of the process.
    func lockSensitiveServicesForShutdown() {
        walletGateway.lock()
    }

    func authorizeWalletSession() async {
        let authorized = await walletGateway.authorizeSession()
        refreshWalletCapabilities()
        showToast(authorized ? "Locus Vault unlocked for this session" : "Locus Vault could not be unlocked")
    }

    func lockWalletSession() {
        walletGateway.lock()
        refreshWalletCapabilities()
    }
}
