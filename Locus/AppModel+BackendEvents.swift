import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The backend WebSocket dispatcher: event dedup into the run timeline
/// and the per-domain switch, plus session activation, streaming block
/// management, lost-connection recovery, and the token flush pipeline.
extension AppModel {
    func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        if type == "run_started" || type == "orchestration_started",
           let runID = event["run_id"] as? String,
           (event["session_id"] as? String ?? currentSessionID) == currentSessionID {
            outputsLibrary.bindRunIdentity(workspace: workspacePath, sessionID: currentSessionID,
                runID: runID, occurredAt: (event["occurred_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        if type != "agent_job_stream",
           event["event_id"] != nil,
           let runEvent = decode(OrchestrationEvent.self, from: event),
           !orchestrationEventIDs.contains(runEvent.id),
           selectedOrchestrationRun?.id == (event["run_id"] as? String)
                || orchestrationRunID == (event["run_id"] as? String)
        {
            orchestrationEventIDs.insert(runEvent.id)
            orchestrationEvents.append(runEvent)
            orchestrationEvents.sort { $0.sequence < $1.sequence }
        }
        switch type {
        case "chatgpt_account_updated":
            Task {
                await providerAccountsModel.refreshChatGPTAccounts()
                await providerAccountsModel.refreshAccountCatalogs(force: true)
            }

        case "chatgpt_usage_updated":
            Task { await providerAccountsModel.refreshActiveChatGPTUsage() }

        case "worker_identity":
            activeWorkerID = event["worker_id"] as? String

        case "session_info":
            if let info = decode(SessionInfo.self, from: event) {
                activeWorkerID = event["worker_id"] as? String ?? activeWorkerID
                computerControl.beginSession(info.sessionID)
                browser.beginSession(info.sessionID)
                syncBrowserProfile()
                sessionInfo = info
                currentSessionID = info.sessionID
                knowledge.watchWorkspaceKnowledge(info.workspaceRoot ?? info.cwd)
                activeTaskRecord = info.task
                // Only when a reply is not mid-flight. `approx_tokens` counts
                // the assistant message once it has been committed, which
                // happens at message_end — the same moment streamingAssistantID
                // clears. A session_info arriving before that (changing
                // permission mode does it, and it is busy-guarded on neither
                // side) does not include the text streamed so far, so clearing
                // the estimate would drop it and the meter would visibly fall.
                if streamingAssistantID == nil {
                    streamedCharsThisTurn = 0
                    streamingReply.resetTurn()
                }
                providerAccountsModel.noteLocalHost(from: info)
                applyWorkspaceProfileIfNeeded(for: info)
                activateSessionOverview(info)
            }

        case "session_started":
            guard let raw = event["session_info"] as? [String: Any],
                  let info = decode(SessionInfo.self, from: raw)
            else { return }
            applySessionStarted(info, reason: event["reason"] as? String)

        case "assistant_item_start":
            guard let itemID = event["item_id"] as? String, !itemID.isEmpty,
                  let kind = event["kind"] as? String,
                  kind == "message" || kind == "reasoning"
            else { return }
            if let existing = blocks.first(where: { $0.sourceItemID == itemID }),
               !existing.isStreaming
            {
                break
            }
            if let runtime = taskWorkers[currentSessionID] {
                runtime.executionState = .running
                runtime.startedAt = runtime.startedAt ?? Date()
                runtime.streamingBlockID = nil
                runtime.streamingText = ""
                runtime.streamingReasoning = ""
                updateBackgroundChatState(runtime)
            }
            let phase = kind == "message"
                ? AssistantPhase.resolved(event["phase"] as? String)
                : nil
            let id = startAssistantStream(sourceItemID: itemID, phase: phase)
            taskWorkers[currentSessionID]?.streamingBlockID = id

        case "assistant_item_delta":
            guard let itemID = event["item_id"] as? String, !itemID.isEmpty,
                  let kind = event["kind"] as? String,
                  kind == "message" || kind == "reasoning",
                  let text = event["text"] as? String, !text.isEmpty
            else { return }
            let existing = blocks.first(where: { $0.sourceItemID == itemID })
            if existing?.isStreaming == false { break }
            if existing == nil {
                let phase = kind == "message"
                    ? AssistantPhase.resolved(event["phase"] as? String)
                    : nil
                startAssistantStream(sourceItemID: itemID, phase: phase)
            }
            guard let block = blocks.first(where: { $0.sourceItemID == itemID }),
                  block.id == streamingAssistantID
            else { break }
            if kind == "reasoning" {
                enqueueReasoning(text, sectionIndex: event["section_index"] as? Int ?? 0)
            } else {
                enqueueToken(text)
            }

        case "assistant_item_end":
            guard let itemID = event["item_id"] as? String, !itemID.isEmpty,
                  let kind = event["kind"] as? String,
                  kind == "message" || kind == "reasoning"
            else { return }
            if blocks.first(where: { $0.sourceItemID == itemID }) == nil {
                let phase = kind == "message"
                    ? AssistantPhase.resolved(event["phase"] as? String)
                    : nil
                startAssistantStream(sourceItemID: itemID, phase: phase)
            }
            flushPendingTokens()
            guard let index = blocks.firstIndex(where: { $0.sourceItemID == itemID }) else {
                break
            }
            let wasStreaming = blocks[index].isStreaming
            let authoritativeText = kind == "message" ? event["text"] as? String : nil
            let sections = kind == "reasoning"
                ? (event["sections"] as? [String] ?? [])
                : nil
            if let phase = event["phase"] as? String, kind == "message" {
                updateTranscriptBlocks {
                    $0[index].assistantPhase = AssistantPhase.resolved(phase)
                }
            }
            if blocks[index].id == streamingAssistantID {
                commitStreamingReply(
                    blocks[index].id,
                    finished: true,
                    authoritativeText: authoritativeText,
                    authoritativeReasoningSections: sections
                )
                streamingAssistantID = nil
            } else {
                updateTranscriptBlocks { transcriptBlocks in
                    if let authoritativeText {
                        transcriptBlocks[index].text = authoritativeText
                    }
                    if let sections {
                        transcriptBlocks[index].reasoningSections = sections.isEmpty ? nil : sections
                        transcriptBlocks[index].reasoningText = sections
                            .joined(separator: "\n\n")
                            .nilIfEmpty
                    }
                    transcriptBlocks[index].isStreaming = false
                }
            }
            if wasStreaming, let runtime = taskWorkers[currentSessionID] {
                runtime.streamingBlockID = nil
                runtime.streamingText = ""
                runtime.streamingReasoning = ""
            }
            if wasStreaming, kind == "message" {
                sessionOverview.emit(.message(role: .assistant, at: Self.sessionTimestamp))
            }
            if wasStreaming { streamRevision += 1 }

        case "message_start":
            if let runtime = taskWorkers[currentSessionID] {
                runtime.executionState = .running
                runtime.startedAt = runtime.startedAt ?? Date()
                runtime.streamingBlockID = nil
                runtime.streamingText = ""
                runtime.streamingReasoning = ""
                updateBackgroundChatState(runtime)
            }
            startAssistantStream()
            taskWorkers[currentSessionID]?.streamingBlockID = streamingAssistantID

        case "token":
            // A token without a preceding message_start (e.g. after a
            // reconnect mid-turn) still deserves a visible bubble.
            if streamingAssistantID == nil {
                startAssistantStream()
            }
            enqueueToken(event["text"] as? String ?? "")

        case "message_end":
            flushPendingTokens()
            if let id = streamingAssistantID { commitStreamingReply(id, finished: true) }
            streamingAssistantID = nil
            if let runtime = taskWorkers[currentSessionID] {
                runtime.streamingBlockID = nil
                runtime.streamingText = ""
                runtime.streamingReasoning = ""
            }
            sessionOverview.emit(.message(role: .assistant, at: Self.sessionTimestamp))
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
                    updateTranscriptBlocks {
                        $0[index].tool?.status = .error
                        $0[index].tool?.result = explanation
                    }
                } else {
                    blocks.append(ChatBlock(kind: .error, text: explanation))
                }
                return
            }
            if let index = blocks.lastIndex(where: { $0.tool?.toolID == toolID }), !toolID.isEmpty {
                updateTranscriptBlocks {
                    $0[index].tool?.status = .awaitingPermission
                    $0[index].tool?.requestID = requestID
                }
                // Publish the in-place tool-card upgrade even though the
                // block count did not change. The native scroll coordinator
                // decides independently whether the viewport should follow.
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
            notifyNeedsAttentionIfInactive()
            announceVoiceAttention(.permission, token: requestID)
            if let runtime = taskWorkers[currentSessionID] {
                runtime.executionState = .waitingPermission
                updateBackgroundChatState(runtime)
            }
            if orchestrationRunID != nil {
                orchestrationState = .waitingPermission
                updateTaskConversation(state: .waitingPermission, event: event)
            }

        case "tool_result":
            let toolID = event["id"] as? String ?? ""
            let denied = event["denied"] as? Bool == true
            let ok = event["ok"] as? Bool == true
            if let index = blocks.firstIndex(where: { $0.tool?.toolID == toolID }) {
                updateTranscriptBlocks {
                    $0[index].tool?.status = denied ? .denied : ok ? .done : .error
                    $0[index].tool?.result = event["result"] as? String
                }
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
            if let runtime = taskWorkers[currentSessionID],
               runtime.executionState == .waitingPermission {
                runtime.executionState = .running
                updateBackgroundChatState(runtime)
            }
            if orchestrationRunID != nil {
                orchestrationState = .running
                updateTaskConversation(state: .running, event: event)
            }
            if let runtime = taskWorkers[currentSessionID] {
                runtime.executionState = .running
                updateBackgroundChatState(runtime)
            }
            recordSessionToolActivity(event)

        case "workspace_changed":
            // The agent touched the tree; the Changes panel is now stale.
            gitWorkspace.refreshStatus()
            knowledge.scheduleWorkspaceKnowledgeReindex(workspacePath)

        case "extensions_changed", "mcp_status", "mcp_credential_refresh",
             "mcp_auth_required", "mcp_input_required", "mcp_input_rejected":
            extensionsModel.ingest(type, event)

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
            // Keep only reasoning text explicitly supplied by the provider;
            // signatures and redacted blocks never enter this event.
            if streamingAssistantID == nil {
                startAssistantStream()
            }
            enqueueReasoning(event["text"] as? String ?? "")

        case "steer_ack":
            let state = event["state"] as? String
            steeringState = state == "after_current_action"
                ? "Waiting for the active action…"
                : "Redirecting generation…"

        case "steer_applied":
            if let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                blocks.append(ChatBlock(kind: .user, text: text))
            }
            steeringState = nil

        case "run_started":
            orchestrationRunID = event["run_id"] as? String
            orchestrationState = .running
            activeWorkerID = event["worker_id"] as? String ?? activeWorkerID
            teamRunLive.apply(type, event)
            if let runID = orchestrationRunID {
                selectedOrchestrationRun = nil
                orchestrationEvents = []
                orchestrationEventIDs = []
                updateTaskConversation(state: .running, event: event)
                Task { @MainActor [weak self] in
                    await self?.loadOrchestrationRun(runID)
                }
            }

        case "orchestration_started":
            orchestrationRunID = event["run_id"] as? String
            orchestrationState = .dispatching
            activeWorkerID = event["worker_id"] as? String ?? activeWorkerID
            teamRunLive.apply(type, event)
            if let runID = orchestrationRunID {
                selectedOrchestrationRun = nil
                orchestrationEvents = []
                orchestrationEventIDs = []
                Task { @MainActor [weak self] in
                    await self?.loadOrchestrationRun(runID)
                }
            }
            updateTaskConversation(state: .dispatching, event: event)
            if persistenceEnabled { Task { await refreshMetadata() } }

        case "dispatcher_started", "dispatcher_completed", "dispatcher_plan_rejected":
            teamRunLive.apply(type, event)

        case "orchestration_state":
            if let state = (event["state"] as? String).flatMap(TeamRunState.init(rawValue:)) {
                if orchestrationState != state { orchestrationState = state }
                updateTaskConversation(state: state, event: event)
            }

        case "dispatch_plan_ready":
            orchestrationState = .waitingDispatchApproval
            teamRunLive.apply(type, event)
            updateTaskConversation(state: .waitingDispatchApproval, event: event)

        case "orchestration_recovery_available":
            if let raw = event["run"] as? [String: Any],
               let run = decode(OrchestrationRun.self, from: raw)
            {
                orchestrationRuns.removeAll { $0.id == run.id }
                orchestrationRuns.insert(run, at: 0)
                showToast("A team run can be resumed")
            }

        case "orchestration_paused":
            orchestrationState = .paused
            if let runID = event["run_id"] as? String {
                Task { @MainActor [weak self] in
                    await self?.loadOrchestrationRun(runID)
                }
            }

        case "orchestration_pause_requested":
            showToast("Pausing at the next safe boundary")

        case "evaluation_started", "evaluation_case_started",
             "evaluation_case_completed", "evaluation_completed":
            evaluations.ingest(type, event)

        case "agent_spawned", "agent_job_started", "agent_job_continuing",
             "agent_branch_stopped", "agent_job_completed", "swarm_telemetry":
            teamRunLive.apply(type, event)

        case "agent_job_incomplete":
            teamRunLive.apply(type, event)
            orchestrationState = .paused

        case "orchestration_completed":
            let completedState = (event["state"] as? String)
                .flatMap(TeamRunState.init(rawValue:)) ?? .completed
            if orchestrationState != completedState { orchestrationState = completedState }
            updateTaskConversation(state: completedState, event: event)
            teamRunLive.apply(type, event)
            if let runID = event["run_id"] as? String {
                // Reconnects can replay this durable terminal event. Only the
                // first copy should start the final metadata + incremental
                // timeline fetch; the live event itself is already deduped.
                if terminalRefreshRunIDs.insert(runID).inserted {
                    Task { @MainActor [weak self] in
                        await self?.refreshOrchestrationRuns(select: runID, terminal: true)
                        await self?.exportOrchestrationToOTLP(runID)
                    }
                }
            }

        case "task_ready":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
                landingFlow.ingest(type, event)
                updateTaskConversation(
                    state: record.state ?? orchestrationState ?? .running,
                    event: event,
                    taskID: record.id
                )
            }

        case "task_state":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
                let state = record.state
                    ?? (event["state"] as? String).flatMap(TeamRunState.init(rawValue:))
                    ?? .completed
                updateTaskConversation(state: state, event: event, taskID: record.id)
            }

        case "task_changes":
            landingFlow.ingest(type, event)

        case "task_applied":
            if let raw = event["task"] as? [String: Any],
               let record = decode(TaskRecord.self, from: raw)
            {
                activeTaskRecord = record
            }
            landingFlow.ingest(type, event)
            showToast("Applied task changes to the workspace")

        case "computer_action_request":
            guard let requestID = event["request_id"] as? String,
                  let tool = event["tool"] as? String,
                  let arguments = event["arguments"] as? [String: Any]
            else { return }
            if let runtime = taskWorkers[currentSessionID] {
                runtime.executionState = .waitingComputer
                updateBackgroundChatState(runtime)
            }
            if orchestrationRunID != nil {
                orchestrationState = .waitingComputer
                updateTaskConversation(state: .waitingComputer, event: event)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let scope = self.liveApplicationTargets[self.currentSessionID]
                let scopedApplicationConnected = scope.map(self.applicationContext.isConnected)
                    ?? false
                guard scope == nil
                    ? self.settings.computerControlEnabled
                    : scopedApplicationConnected
                else {
                    _ = self.conversationBackend.send([
                        "type": "computer_action_result",
                        "request_id": requestID,
                        "result": ["error": "Computer Control is not enabled for this task."],
                    ])
                    return
                }
                let result = await self.computerControl.perform(
                    tool: tool,
                    arguments: arguments,
                    hostedProvider: self.activeAccount?.displayName,
                    scope: scope,
                    timeoutMilliseconds: event["timeout_ms"] as? Int ?? 60_000
                )
                _ = self.conversationBackend.send([
                    "type": "computer_action_result",
                    "request_id": requestID,
                    "result": result,
                ])
                if self.orchestrationRunID != nil {
                    self.orchestrationState = .running
                    self.updateTaskConversation(state: .running, event: event)
                }
                if let runtime = self.taskWorkers[self.currentSessionID] {
                    runtime.executionState = .running
                    self.updateBackgroundChatState(runtime)
                }
            }

        case "computer_control_status":
            if (event["enabled"] as? Bool) != true,
               settings.computerControlEnabled || currentLiveApplicationTarget != nil {
                showToast("Computer Control is unavailable from the native broker")
            }

        case "simulator_action_request":
            runSimulatorAction(event, workspacePath: workspacePath, on: conversationBackend)

        case "simulator_control_status":
            if (event["enabled"] as? Bool) != true,
               settings.simulatorControlEnabled,
               currentSimulatorTarget != nil {
                showToast("iOS Simulator control is unavailable from the native broker")
            }

        case "browser_action_request":
            runBrowserAction(event, on: conversationBackend)

        case "browser_control_status":
            if (event["enabled"] as? Bool) != true, settings.browserEnabled {
                showToast("The browser is unavailable from the native broker")
            }

        case "notes_action_request":
            runNotesAction(event, workspacePath: workspacePath, on: conversationBackend)

        case "notes_control_status":
            if (event["enabled"] as? Bool) != true {
                showToast("Notes are unavailable from the native broker")
            }

        case "wallet_action_request":
            runWalletAction(event, on: conversationBackend)

        case "wallet_control_status":
            let sameSession = (event["session_id"] as? String)
                == (walletGateway.capability?["session_id"] as? String)
            if (event["enabled"] as? Bool) != walletGateway.agentToolingAvailable
                || (walletGateway.agentToolingAvailable && !sameSession) {
                showToast("The Locus Vault signer is unavailable")
            }

        case "connector_action_request":
            eventAutomations.handleAction(
                event, workspacePath: workspacePath, on: conversationBackend
            )

        case "connector_control_status":
            break

        case "todo_update":
            if let raw = event["todos"] as? [[String: Any]] {
                let updatedTodos = raw.compactMap { decode(TodoItem.self, from: $0) }
                let changed = updatedTodos != todos
                todos = updatedTodos
                if todos.isEmpty {
                    // A prompt offering to implement zero steps is nonsense;
                    // the agent emptying the list withdraws the plan.
                    planApprovalPending = false
                    activePlan = nil
                } else if changed {
                    planTodosChangedThisTurn = true
                }
                // Badge rather than switch: being pulled off the tab you are
                // reading mid-run is the complaint this replaces.
                if !todos.isEmpty, inspectorTab != .plan || inspectorCollapsed {
                    planHasUnseenUpdate = true
                }
                synchronizeSessionPlan(todos)
            }

        case "plan_ready":
            if let raw = event["plan"] as? [String: Any],
               let plan = decode(PlanDocument.self, from: raw),
               !plan.steps.isEmpty
            {
                activePlan = plan
                planReadyThisTurn = true
                todos = plan.steps.map { TodoItem(content: $0, status: .pending) }
                synchronizeSessionPlan(todos)
                if inspectorTab != .plan || inspectorCollapsed {
                    planHasUnseenUpdate = true
                }
            }

        case "question_ready":
            if let raw = event["question"] as? [String: Any],
               let question = decode(UserQuestion.self, from: raw),
               !question.question.isEmpty || !question.options.isEmpty
            {
                capturedQuestionThisTurn = question
            }

        case "question_required":
            let request = decode(AgentQuestionRequest.self, from: event)
            if let request, !request.id.isEmpty, !request.questions.isEmpty {
                pendingBlockingQuestion = request
            } else if let requestID = event["request_id"] as? String,
                      !requestID.isEmpty {
                // A worker is blocked on every question_required event. If
                // this client cannot render it, explicitly cancel instead of
                // leaving the chat wedged until Stop.
                _ = conversationBackend.send([
                    "type": "question_response",
                    "request_id": requestID,
                    "action": "cancel",
                    "answers": [],
                ])
                blocks.append(ChatBlock(
                    kind: .error,
                    text: "The agent asked a question this version of Locus cannot display."
                ))
            }

        case "question_resolved":
            if let requestID = event["request_id"] as? String,
               pendingBlockingQuestion?.id == requestID {
                pendingBlockingQuestion = nil
            }

        case "background_services_changed":
            backgroundServicesModel.refreshBackgroundServices(recordingOutputs: (event["action"] as? String) == "start")

        case "turn_done":
            completeAutomationWorkflowStep(from: event)
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            flushPendingBrowserCapability()
            let reason = event["reason"] as? String ?? "complete"
            recordAutomaticModelRoutingOutcome(
                sessionID: currentSessionID,
                reason: reason,
                backendDurationMilliseconds: event["duration_ms"] as? Int
            )
            let completedRunID = event["run_id"] as? String
            let dispatchedMode = turnDispatchedMode
                ?? (turnDispatchedInPlanMode ? .plan : nil)
            if reason == "complete", dispatchedMode == .work {
                // Plan execution rides Work since GSD retired. For any Work
                // turn, a todo still in progress after a *complete* turn is
                // one the model forgot to close, so the tidy stays safe.
                reconcileFinishedPlanStep()
            }
            if turnDispatchedTeamRunID == nil {
                appendTurnCompletion(
                    reason: reason,
                    mode: dispatchedMode,
                    backendDurationMilliseconds: event["duration_ms"] as? Int,
                    modelCallLimit: event["model_call_limit"] as? Int
                )
            }
            finishSessionOverview(
                reason: reason,
                durationMilliseconds: event["duration_ms"] as? Int
            )
            isBusy = false
            var completedWorker: ChatWorkerRuntime?
            if let runtime = taskWorkers[currentSessionID] {
                let finalState = runtime.dispatchedTeamRunID == nil
                    ? (reason == "complete" ? TeamRunState.completed : .failed)
                    : (orchestrationState ?? runtime.executionState)
                finishChatRuntime(
                    runtime,
                    state: finalState
                )
                flushPendingConnectorCapability(for: runtime)
                completedWorker = runtime
            }
            flushPendingConnectorCapability()
            if let completedWorker {
                prepareChatWorkerForNextDispatch(completedWorker)
            } else {
                eventAutomations.wakeDispatcher()
                syncPreferredPermissionMode(to: conversationBackend)
            }
            pendingRetry = false
            steeringState = nil
            extensionsModel.mcpInputRequest = nil
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            streamingReply.resetTurn()
            let assistantText = blocks.last(where: { $0.kind == .assistant })?.text ?? ""
            if reason == "complete" {
                if let captured = capturedQuestionThisTurn {
                    pendingUserQuestion = captured
                } else if dispatchedMode == .grill,
                          let detected = QuestionSignalDetector.question(from: assistantText)
                {
                    // The Grill skill's ❓ block, for a model that wrote the
                    // question but skipped the tool, or a backend without it.
                    pendingUserQuestion = detected
                }
            }
            if reason == "complete", turnDispatchedInPlanMode, selectedMode == .plan {
                if !planReadyThisTurn,
                   let fallback = PlanSignalDetector.document(
                    from: assistantText,
                    changedTodos: planTodosChangedThisTurn ? todos : []
                   )
                {
                    activePlan = fallback
                    planReadyThisTurn = true
                }
                // A structured question outranks the plan prompt: the model
                // is explicitly still asking, not proposing.
                planApprovalPending = planReadyThisTurn
                    && pendingUserQuestion == nil
                    && !(activePlan?.steps.isEmpty ?? true)
                    && !PlanSignalDetector.isClarifyingResponse(assistantText)
            }
            completeVoiceTurnIfNeeded()
            planTodosChangedThisTurn = false
            planReadyThisTurn = false
            capturedQuestionThisTurn = nil
            turnDispatchedInPlanMode = false
            turnDispatchedMode = nil
            turnDispatchedTeamRunID = nil
            turnStartedAt = nil
            notifyTurnCompleteIfInactive()
            if persistenceEnabled {
                Task { await refreshMetadata() }
            }
            if let completedRunID, terminalRefreshRunIDs.insert(completedRunID).inserted {
                Task { @MainActor [weak self] in
                    await self?.refreshOrchestrationRuns(
                        select: completedRunID, terminal: true
                    )
                    await self?.exportOrchestrationToOTLP(completedRunID)
                }
            }
            // Before the queue drains: a model chosen mid-turn is meant for
            // the messages waiting behind it.
            applyPendingProviderSwitchIfNeeded()
            if let replacement = pendingStopAndSend {
                pendingStopAndSend = nil
                send(replacement, preservingDraftOnFailure: false, requeueingOnFailure: true)
                return
            }
            Task { @MainActor [weak self] in
                self?.drainQueuedMessages()
                self?.applyPendingProxyRouteRestartIfPossible()
            }

        case "error":
            voiceControl.turnFailed()
            flushPendingTokens()
            finalizeStreamingBlocks()
            resolveDanglingPermissions()
            pendingRetry = false
            steeringState = nil
            planApprovalPending = false
            clearPendingQuestion()
            planTodosChangedThisTurn = false
            turnDispatchedInPlanMode = false
            turnDispatchedMode = nil
            turnDispatchedTeamRunID = nil
            pendingSessionReset = false
            pendingCheckpointRestore = nil
            pendingRewindDraft = nil
            streamingAssistantID = nil
            streamedCharsThisTurn = 0
            streamingReply.resetTurn()
            let errorMessage = annotatingRejectedKey(
                event["message"] as? String ?? "Unknown agent error"
            )
            blocks.append(
                ChatBlock(
                    kind: .error,
                    text: errorMessage
                )
            )
            if let running = sessionOverview.state.plan.first(where: { $0.state == .running }) {
                sessionOverview.emit(.stepState(
                    stepID: running.id,
                    state: .failed,
                    at: Self.sessionTimestamp
                ))
            }
            sessionOverview.emit(.status(
                status: .error,
                reason: errorMessage,
                at: Self.sessionTimestamp
            ))
            if let runtime = taskWorkers[currentSessionID] {
                runtime.lastError = event["message"] as? String
                runtime.executionState = .failed
                updateBackgroundChatState(runtime)
            }
            // `error` describes the failed operation; the backend still emits
            // `turn_done` after it has finished unwinding. Stay busy until that
            // terminal event so queued messages and state changes cannot race
            // the worker's final session writes.

        case "command_error":
            if event["operation"] as? String == "set_connector_control" {
                // This is an internal capability handshake, not a failed user
                // request. Retry after the turn without polluting its transcript.
                deferRejectedConnectorCapability()
                return
            }
            let message = annotatingRejectedKey(
                event["message"] as? String ?? "The command was rejected."
            )
            blocks.append(ChatBlock(kind: .error, text: message))
            showToast(message)

        case "slash_result":
            isBusy = false
            applyPendingProviderSwitchIfNeeded()
            if event["command"] as? String == "clear" {
                blocks = []
                todos = []
                activePlan = nil
                planApprovalPending = false
                clearPendingQuestion()
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

    func applySessionStarted(_ info: SessionInfo, reason: String?) {
        let previousSessionID = currentSessionID
        let isDuplicateAcknowledgement = currentSessionID == info.sessionID
            && !pendingSessionReset
            && !pendingRetry
            && pendingCheckpointRestore == nil
        computerControl.beginSession(info.sessionID)
        browser.beginSession(info.sessionID)
        sessionInfo = info
        syncBrowserProfile()
        currentSessionID = info.sessionID
        if previousSessionID != info.sessionID {
            voiceControl.sessionDidChange()
        }
        activeTaskRecord = info.task
        let startsFreshOverview = pendingSessionReset
            || reason == "clear_chat"
            || reason == "workspace_chat"
            || reason == "deleted_active"
        if startsFreshOverview, !previousSessionID.isEmpty, previousSessionID != info.sessionID {
            liveApplicationTargets.removeValue(forKey: previousSessionID)
            simulatorControl.detach(sessionID: previousSessionID)
        }
        activateSessionOverview(info, reset: startsFreshOverview)
        sendComputerControlCapability()
        sendSimulatorControlCapability()
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
            activePlan = checkpoint.activePlan
            planApprovalPending = false
            // Questions are deliberately not persisted in checkpoints.
            clearPendingQuestion()
            contextFiles = checkpoint.contextFiles
            queuedMessages = []
            restoredTranscriptContext = ChatTranscriptBuilder.transcriptContext(from: checkpoint.blocks)
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
            synchronizeSessionPlan(todos)
        } else if reason == "retry" || pendingRetry {
            flushPendingTokens()
            if let userIndex = blocks.lastIndex(where: { $0.kind == .user }) {
                blocks = Array(blocks.prefix(through: userIndex))
            }
            todos = []
            activePlan = nil
            planApprovalPending = false
            clearPendingQuestion()
            planTodosChangedThisTurn = false
            pendingRetry = false
            isBusy = true
            sessionOverview.emit(.status(
                status: .running,
                reason: nil,
                at: Self.sessionTimestamp
            ))
        } else if pendingSessionReset
                    || reason == "clear_chat"
                    || reason == "workspace_chat"
                    || reason == "deleted_active"
        {
            flushPendingTokens()
            blocks = []
            todos = []
            activePlan = nil
            planApprovalPending = false
            clearPendingQuestion()
            queuedMessages = []
            streamingAssistantID = nil
            streamingReply.resetTurn()
            restoredTranscriptContext = nil
            pendingSessionReset = false
            isBusy = false
            orchestrationRunID = nil
            orchestrationState = nil
            activeWorkerID = nil
            dispatcherActivity = nil
            dispatcherValidationReason = nil
            teamRunLive.restoreActivities([])
            teamRunLive.resetMetering()
            landingFlow.taskHasChanges = false
            landingFlow.taskPatchBytes = 0
            synchronizeSessionPlan([])
            showToast(reason == "deleted_active" ? "Fresh chat opened" : "Fresh chat started")
        }
        if persistenceEnabled {
            Task { await refreshMetadata() }
        }
    }

    @discardableResult
    private func startAssistantStream(
        sourceItemID: String? = nil,
        phase: AssistantPhase? = nil
    ) -> UUID {
        if let sourceItemID,
           let existing = blocks.first(where: { $0.sourceItemID == sourceItemID }) {
            if existing.isStreaming { streamingAssistantID = existing.id }
            return existing.id
        }
        flushPendingTokens()
        if let current = streamingAssistantID {
            commitStreamingReply(current, finished: true)
        }
        let id = UUID()
        streamingAssistantID = id
        isBusy = true
        blocks.append(ChatBlock(
            id: id,
            kind: .assistant,
            assistantPhase: phase,
            sourceItemID: sourceItemID,
            isStreaming: true
        ))
        streamingReply.begin(id: id)
        return id
    }

    /// No assistant bubble may stay in the streaming state once the turn is
    /// over — a missed message_end otherwise leaves a blinking cursor forever.
    func finalizeStreamingBlocks() {
        if let id = streamingAssistantID {
            commitStreamingReply(id, finished: true)
        }
        updateTranscriptBlocks { transcriptBlocks in
            for index in transcriptBlocks.indices where transcriptBlocks[index].isStreaming {
                transcriptBlocks[index].isStreaming = false
            }
        }
    }

    private func commitStreamingReply(
        _ id: UUID,
        finished: Bool,
        authoritativeText: String? = nil,
        authoritativeReasoningSections: [String]? = nil
    ) {
        guard let snapshot = streamingReply.finish(
            id: id,
            authoritativeText: authoritativeText,
            authoritativeReasoningSections: authoritativeReasoningSections
        ),
              let index = blocks.firstIndex(where: { $0.id == id })
        else { return }
        updateTranscriptBlocks {
            $0[index].text = snapshot.text
            $0[index].reasoningText = snapshot.reasoning.nilIfEmpty
            $0[index].reasoningSections = snapshot.reasoningSections.isEmpty
                ? nil
                : snapshot.reasoningSections
            if finished { $0[index].isStreaming = false }
        }
    }

    /// A normally completed Build turn is authoritative evidence that the
    /// step it left active has finished. Pending steps remain pending: this
    /// fixes the common final-step bookkeeping omission without claiming work
    /// the model never started.
    private func reconcileFinishedPlanStep() {
        guard todos.contains(where: { $0.status == .inProgress }) else { return }
        todos = todos.map { todo in
            guard todo.status == .inProgress else { return todo }
            return TodoItem(content: todo.content, status: .completed)
        }
        if inspectorTab != .plan || inspectorCollapsed {
            planHasUnseenUpdate = true
        }
    }

    private func appendTurnCompletion(
        reason: String,
        mode: WorkMode?,
        backendDurationMilliseconds: Int?,
        modelCallLimit: Int? = nil
    ) {
        let measured = turnStartedAt.map {
            max(Int(Date().timeIntervalSince($0) * 1_000), 0)
        }
        guard let duration = backendDurationMilliseconds ?? measured else { return }
        // A repeated terminal event must not leave a row of duplicate marks.
        guard blocks.last?.completion == nil else { return }
        let outcome = TurnCompletion.Outcome(reason: reason)
        let completion = TurnCompletion(
            outcome: outcome,
            mode: mode,
            durationMilliseconds: duration,
            // Carried only for the outcome it explains, so an ordinary finished
            // turn does not persist a number nothing reads.
            iterationLimit: outcome == .maxIterations
                ? sessionInfo?.maxIterations
                : outcome == .modelCallBudget ? modelCallLimit : nil
        )
        blocks.append(ChatBlock(kind: .note, completion: completion))
    }

    /// No card may stay awaiting once the turn is over: a decision can no
    /// longer matter, and a stuck awaiting card would disable send and
    /// clear-chat forever.
    private func resolveDanglingPermissions() {
        updateTranscriptBlocks { transcriptBlocks in
            for index in transcriptBlocks.indices
            where transcriptBlocks[index].tool?.status == .awaitingPermission {
                transcriptBlocks[index].tool?.status = .error
                transcriptBlocks[index].tool?.result =
                    "The turn ended before this request was answered."
            }
        }
    }

    /// Called when the WebSocket drops mid-session: resolve every UI state
    /// that only a backend event could clear, so nothing stays stuck.
    func recoverFromLostConnection() {
        cancelSimulatorActions()
        flushPendingTokens()
        finalizeStreamingBlocks()
        streamingAssistantID = nil
        streamedCharsThisTurn = 0
        streamingReply.resetTurn()
        turnStartedAt = nil
        isBusy = false
        pendingRetry = false
        // A pending "implement this plan?" survives the blip on purpose: the
        // decision is client-side state, and answering "implement" while
        // still disconnected is caught by resolvePlanApproval's guard.
        planTodosChangedThisTurn = false
        turnDispatchedInPlanMode = false
        turnDispatchedMode = nil
        turnDispatchedTeamRunID = nil
        pendingSessionReset = false
        pendingCheckpointRestore = nil
        pendingRewindDraft = nil
        sessionResetWatchdog?.cancel()
        updateTranscriptBlocks { transcriptBlocks in
            for index in transcriptBlocks.indices
            where transcriptBlocks[index].tool?.status == .awaitingPermission
                || transcriptBlocks[index].tool?.status == .running
            {
                transcriptBlocks[index].tool?.status = .error
                transcriptBlocks[index].tool?.result =
                    "The connection to the local agent was lost before this finished."
            }
        }
    }

    private func enqueueToken(_ token: String) {
        guard !token.isEmpty else { return }
        pendingTokens += token
        scheduleStreamFlush()
    }

    private func enqueueReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        pendingReasoning += text
        scheduleStreamFlush()
    }

    private func enqueueReasoning(_ text: String, sectionIndex: Int) {
        guard !text.isEmpty else { return }
        pendingReasoningSections[max(sectionIndex, 0), default: ""] += text
        scheduleStreamFlush()
    }

    /// A single publication on the next display refresh keeps text growth and
    /// native scroll anchoring on the same visual frame.
    private func scheduleStreamFlush() {
        streamFlushDriver.request()
    }

    func flushPendingTokens() {
        streamFlushDriver.cancelPending()
        guard !pendingTokens.isEmpty || !pendingReasoning.isEmpty
                || !pendingReasoningSections.isEmpty,
              streamingAssistantID != nil
        else {
            pendingTokens = ""
            pendingReasoning = ""
            pendingReasoningSections = [:]
            return
        }
        streamingReply.append(
            text: pendingTokens,
            reasoning: pendingReasoning,
            reasoningSections: pendingReasoningSections
        )
        let publishedCharacters = pendingTokens.count
            + pendingReasoning.count
            + pendingReasoningSections.values.reduce(0) { $0 + $1.count }
        streamedCharsThisTurn += publishedCharacters
        pendingTokens = ""
        pendingReasoning = ""
        pendingReasoningSections = [:]
    }

    func updateSession(_ session: SessionSummary, body: [String: Any], success: String) {
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
}
