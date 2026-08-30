import AppKit
import Foundation

// MARK: - Mobile companion

extension AppModel {
    func beginCompanionPairing() {
        companionPairingError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                companionPairingPayload = try await companionGateway.beginPairing()
            } catch {
                companionPairingPayload = nil
                companionPairingError = error.localizedDescription
            }
        }
    }

    func dismissCompanionPairing() {
        companionPairingPayload = nil
        companionPairingError = nil
    }

    func revokeCompanionDevice(_ device: CompanionDeviceDescription) {
        Task { await companionGateway.revoke(deviceID: device.id) }
    }

    func revokeAllCompanionDevices() {
        Task { await companionGateway.revokeAll() }
    }

    func resetCompanionCertificate() {
        companionPairingPayload = nil
        companionPairingError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await companionGateway.resetCertificate()
                showToast("Mobile Access security was reset")
            } catch {
                companionPairingError = error.localizedDescription
            }
        }
    }

    func handleCompanionRequest(_ request: CompanionRequest) async -> CompanionResponse {
        do {
            let data: JSONValue
            switch request.method {
            case .pairExchange:
                return .failure(
                    id: request.id, code: "invalid_method",
                    message: "Pairing is handled before commands are authorized."
                )
            case .statusGet:
                data = companionStatusPayload()
            case .chatsList:
                await refreshMetadata()
                data = companionChatsPayload()
            case .chatGet:
                data = try await companionChatPayload(request.payload)
            case .chatSend:
                data = try await companionDispatchChat(request, create: false)
            case .chatCreate:
                data = try await companionDispatchChat(request, create: true)
            case .activityList:
                await activity.refreshActivityRuns(announceFailure: false)
                data = companionActivityPayload()
            case .runStop:
                data = try companionStopRun(request.payload)
            case .approvalRespond:
                data = try companionRespondToApproval(request.payload)
            case .schedulesList:
                await schedule.refreshScheduledTasks(announceFailure: false)
                data = companionSchedulesPayload()
            case .scheduleRunNow:
                data = try await companionRunSchedule(request.payload)
            case .scheduleSetEnabled:
                data = try await companionSetScheduleEnabled(request.payload)
            }
            return .success(id: request.id, data: data)
        } catch let error as CompanionProtocolError {
            return .failure(
                id: request.id, code: error.code,
                message: error.message, retryable: error.retryable
            )
        } catch {
            return .failure(
                id: request.id, code: "command_failed",
                message: error.localizedDescription
            )
        }
    }

    func companionPublishedEvents() -> [CompanionPublishedEvent] {
        let events = [
            CompanionPublishedEvent(name: "chat.updated", data: companionChatEventPayload()),
            CompanionPublishedEvent(name: "activity.updated", data: companionActivityPayload()),
            CompanionPublishedEvent(name: "schedule.updated", data: companionSchedulesPayload()),
            CompanionPublishedEvent(name: "approval.required", data: companionApprovalsPayload()),
        ]
        return events
    }

    private func companionStatusPayload() -> JSONValue {
        .object([
            "mac_name": .string(Host.current().localizedName ?? "Mac"),
            "agent_online": .bool(agentRuntimePhase.isOnline),
            "model_online": .bool(modelRuntimePhase.isOnline),
            "foreground_chat_id": .string(currentSessionID),
            "running_count": .number(Double(companionRunningRuns.count)),
            "pending_approvals": .number(Double(companionApprovalObjects().count)),
            "approvals": companionApprovalsPayload(),
            "next_schedule": schedule.nextScheduledTask.map(companionScheduleObject) ?? .null,
            "workspaces": .array(companionWorkspaces().map { workspace in
                .object([
                    "id": .string(companionWorkspaceID(workspace.path)),
                    "name": .string(URL(fileURLWithPath: workspace.path).lastPathComponent),
                    "environment": .string(workspace.environment.rawValue),
                ])
            }),
        ])
    }

    private func companionChatsPayload() -> JSONValue {
        .array(sessions.prefix(200).map { session in
            let run = visibleActivityRuns.first { $0.sessionID == session.id }
            return .object([
                "id": .string(session.id),
                "title": .string(String(session.displayTitle.prefix(160))),
                "preview": .string(String(SessionSummary.cleanPreview(session.preview).prefix(500))),
                "updated_at": .number(session.mtime),
                "workspace": .string(URL(fileURLWithPath: session.workspacePath ?? "").lastPathComponent),
                "environment": .string(session.executionEnvironment.rawValue),
                "state": run.map { .string($0.state) } ?? .string("idle"),
            ])
        })
    }

    private func companionChatEventPayload() -> JSONValue {
        var streams: [JSONValue] = taskWorkers.values.compactMap { runtime in
            guard !runtime.streamingText.isEmpty else { return nil }
            return .object([
                "chat_id": .string(runtime.sessionID),
                "text": .string(String(runtime.streamingText.suffix(120_000))),
            ])
        }
        if let assistant = blocks.last(where: {
            $0.kind == .assistant && $0.isStreaming && !$0.text.isEmpty
        }) {
            streams.append(.object([
                "chat_id": .string(currentSessionID),
                "text": .string(String(assistant.text.suffix(120_000))),
            ]))
        }
        return .object([
            "chats": companionChatsPayload(),
            "streams": .array(streams),
        ])
    }

    private func companionChatPayload(_ payload: [String: JSONValue]) async throws -> JSONValue {
        guard let sessionID = CompanionPayload.string("chat_id", in: payload),
              sessions.contains(where: { $0.id == sessionID }) else {
            throw CompanionProtocolError(code: "chat_not_found", message: "That chat is no longer available.")
        }
        let detail = try await backend.get(
            "/api/sessions/\(sessionID)", as: SessionDetailResponse.self
        )
        let messages: [JSONValue] = detail.messages.suffix(500).compactMap { message in
            guard message.role == "user" || message.role == "assistant" else { return nil }
            let visible = message.role == "user"
                ? ChatTranscriptBuilder.displayUserText(message.content)
                : message.content
            guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .object([
                "role": .string(message.role),
                "content": .string(String(visible.prefix(120_000))),
                "run_id": message.runID.map(JSONValue.string) ?? .null,
            ])
        }
        return .object([
            "id": .string(detail.id),
            "title": .string(detail.title ?? "Saved chat"),
            "messages": .array(messages),
        ])
    }

    private func companionDispatchChat(
        _ request: CompanionRequest, create: Bool
    ) async throws -> JSONValue {
        guard let prompt = CompanionPayload.string("prompt", in: request.payload),
              !prompt.isEmpty else {
            throw CompanionProtocolError(code: "prompt_required", message: "Enter a message first.")
        }
        guard prompt.utf8.count <= 240_000 else {
            throw CompanionProtocolError(code: "prompt_too_large", message: "That message is too large.")
        }
        let modeRaw = CompanionPayload.string("mode", in: request.payload) ?? WorkMode.work.rawValue
        // `canonical` keeps older mobile builds working: they still say "build".
        guard let mode = WorkMode.canonical(modeRaw) else {
            throw CompanionProtocolError(code: "invalid_mode", message: "Choose Ask, Work, Plan, or Grill.")
        }
        var body: [String: Any] = [
            "request_id": request.id,
            "prompt": prompt,
            "mode": mode.rawValue,
        ]
        if create {
            guard let workspaceID = CompanionPayload.string("workspace_id", in: request.payload),
                  let workspace = companionWorkspaces().first(where: {
                      companionWorkspaceID($0.path) == workspaceID
                  }) else {
                throw CompanionProtocolError(
                    code: "workspace_not_found",
                    message: "Choose a workspace that is still available on the Mac."
                )
            }
            guard FileManager.default.fileExists(atPath: workspace.path),
                  workspaceAccess.activateStored(path: workspace.path) else {
                throw CompanionProtocolError(
                    code: "workspace_unavailable",
                    message: "Open this workspace again on the Mac to restore access."
                )
            }
            let route = stableWorkspaceRoute(for: workspace.path)
            let account = route.accountID.flatMap { accountID in
                providerAccounts.first { $0.id.uuidString == accountID }
            }
            let model = route.model.nilIfEmpty
                ?? account.map(routedModel(for:))
                ?? selectedModel
            guard model != "No model", !model.isEmpty else {
                throw CompanionProtocolError(
                    code: "model_unavailable", message: "Choose a model on the Mac first."
                )
            }
            body["workspace_root"] = workspace.path
            body["execution_environment"] = workspace.environment.rawValue
            body["provider"] = account == nil ? "ollama" : (account!.kind == .chatGPT ? "chatgpt" : "remote")
            body["provider_account_id"] = account?.id.uuidString ?? ""
            body["model"] = model
        } else {
            guard let sessionID = CompanionPayload.string("chat_id", in: request.payload),
                  sessions.contains(where: { $0.id == sessionID }) else {
                throw CompanionProtocolError(code: "chat_not_found", message: "That chat is no longer available.")
            }
            body["session_id"] = sessionID
        }
        let response: CompanionChatDispatchResponse = try await backend.post(
            "/api/companion/chats", body: body, timeout: 30,
            as: CompanionChatDispatchResponse.self
        )
        await refreshMetadata()
        await activity.refreshActivityRuns(announceFailure: false)
        if response.run.state == "queued",
           restoredQueuedRunIDs.insert(response.run.id).inserted {
            await dispatchPersistedQueuedRun(response.run)
        }
        return .object([
            "claimed": .bool(response.claimed),
            "chat_id": response.run.sessionID.map(JSONValue.string) ?? .null,
            "run_id": .string(response.run.id),
            "state": .string(response.run.state),
        ])
    }

    private func companionActivityPayload() -> JSONValue {
        .array(visibleActivityRuns.prefix(200).map { run in
            .object([
                "id": .string(run.id),
                "chat_id": run.sessionID.map(JSONValue.string) ?? .null,
                "chat_title": .string(sessions.first(where: { $0.id == run.sessionID })?.displayTitle ?? "Saved chat"),
                "state": .string(run.state),
                "kind": .string(run.runKind ?? "solo"),
                "environment": .string(run.executionEnvironment ?? "local"),
                "updated_at": .number(run.updatedAt),
                "can_stop": .bool(["queued", "running", "dispatching", "reviewing"].contains(run.state)),
            ])
        })
    }

    private func companionStopRun(_ payload: [String: JSONValue]) throws -> JSONValue {
        guard let runID = CompanionPayload.string("run_id", in: payload),
              let run = visibleActivityRuns.first(where: { $0.id == runID }) else {
            throw CompanionProtocolError(code: "run_not_found", message: "That run is no longer available.")
        }
        stopActivityRun(run)
        return .object(["run_id": .string(runID), "stopping": .bool(true)])
    }

    private func companionRespondToApproval(_ payload: [String: JSONValue]) throws -> JSONValue {
        guard let kind = CompanionPayload.string("kind", in: payload),
              let decision = CompanionPayload.string("decision", in: payload) else {
            throw CompanionProtocolError(code: "invalid_approval", message: "Choose an approval response.")
        }
        if kind == "plan" {
            guard let sessionID = CompanionPayload.string("chat_id", in: payload),
                  sessionID == currentSessionID, planApprovalPending else {
                throw CompanionProtocolError(code: "approval_expired", message: "That plan is no longer waiting.")
            }
            guard ["approve", "cancel"].contains(decision) else {
                throw CompanionProtocolError(code: "invalid_approval", message: "Choose Approve or Cancel.")
            }
            resolvePlanApproval(decision == "approve" ? .proceed : .cancel)
            return .object(["resolved": .bool(true)])
        }
        if kind == "question" {
            guard let sessionID = CompanionPayload.string("chat_id", in: payload),
                  sessionID == currentSessionID,
                  let question = pendingUserQuestion else {
                throw CompanionProtocolError(code: "approval_expired", message: "That question is no longer waiting.")
            }
            if decision == "dismiss" {
                dismissUserQuestion()
                return .object(["resolved": .bool(true)])
            }
            guard isAgentOnline else {
                throw CompanionProtocolError(code: "runtime_offline", message: "That chat is no longer connected.", retryable: true)
            }
            let freeText = CompanionPayload.string("text", in: payload) ?? ""
            let option = question.options.first {
                $0.label.caseInsensitiveCompare(decision) == .orderedSame
            }
            guard option != nil || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CompanionProtocolError(code: "invalid_approval", message: "Choose an answer or type one.")
            }
            resolveUserQuestion(option: option, freeText: freeText)
            return .object(["resolved": .bool(true)])
        }
        guard let runID = CompanionPayload.string("run_id", in: payload),
              let run = visibleActivityRuns.first(where: { $0.id == runID }),
              let sessionID = run.sessionID,
              let runtime = taskWorkers[sessionID],
              let event = runtime.pendingForegroundEvent else {
            throw CompanionProtocolError(code: "approval_expired", message: "That approval is no longer waiting.")
        }
        if kind == "permission" {
            guard ["allow_once", "deny"].contains(decision),
                  let requestID = event["request_id"] as? String else {
                throw CompanionProtocolError(code: "invalid_approval", message: "Choose Allow Once or Deny.")
            }
            guard runtime.service.send([
                "type": "permission_decision", "request_id": requestID,
                "decision": decision == "allow_once" ? "once" : "deny",
            ]) else {
                throw CompanionProtocolError(code: "runtime_offline", message: "That chat is no longer connected.", retryable: true)
            }
        } else if kind == "dispatch" {
            guard ["approve", "cancel"].contains(decision),
                  runtime.service.send([
                      "type": "dispatch_decision", "run_id": runID,
                      "action": decision == "approve" ? "run" : "cancel",
                  ]) else {
                throw CompanionProtocolError(code: "runtime_offline", message: "That team run is no longer connected.", retryable: true)
            }
        } else {
            throw CompanionProtocolError(code: "invalid_approval", message: "That approval type is not supported on mobile.")
        }
        runtime.pendingForegroundEvent = nil
        runtime.executionState = .running
        updateBackgroundChatState(runtime)
        return .object(["resolved": .bool(true)])
    }

    private func companionSchedulesPayload() -> JSONValue {
        .array(schedule.scheduledTasks.map(companionScheduleObject))
    }

    private func companionScheduleObject(_ task: ScheduledTask) -> JSONValue {
        .object([
            "id": .string(task.id),
            "name": .string(task.name),
            "enabled": .bool(task.enabled),
            "next_run_at": task.nextRunAt.map(JSONValue.number) ?? .null,
            "last_run_at": task.lastRunAt.map(JSONValue.number) ?? .null,
            "last_run_id": task.lastRunID.map(JSONValue.string) ?? .null,
            "last_error": task.lastError.map { .string(String($0.prefix(1_000))) } ?? .null,
        ])
    }

    private func companionRunSchedule(_ payload: [String: JSONValue]) async throws -> JSONValue {
        guard let scheduleID = CompanionPayload.string("schedule_id", in: payload),
              let task = schedule.scheduledTasks.first(where: { $0.id == scheduleID }) else {
            throw CompanionProtocolError(code: "schedule_not_found", message: "That schedule is no longer available.")
        }
        await schedule.dispatchSchedule(
            task, trigger: "manual", requestID: UUID().uuidString,
            announceFailure: false
        )
        return .object(["schedule_id": .string(scheduleID), "queued": .bool(true)])
    }

    private func companionSetScheduleEnabled(_ payload: [String: JSONValue]) async throws -> JSONValue {
        guard let scheduleID = CompanionPayload.string("schedule_id", in: payload),
              let enabled = CompanionPayload.bool("enabled", in: payload),
              schedule.scheduledTasks.contains(where: { $0.id == scheduleID }) else {
            throw CompanionProtocolError(code: "schedule_not_found", message: "That schedule is no longer available.")
        }
        let updated: ScheduledTask = try await backend.patch(
            "/api/schedules/\(scheduleID)", body: ["enabled": enabled],
            as: ScheduledTask.self
        )
        schedule.replaceScheduledTask(updated)
        return companionScheduleObject(updated)
    }

    private var companionRunningRuns: [OrchestrationRun] {
        visibleActivityRuns.filter {
            ["queued", "dispatching", "running", "reviewing", "waiting_permission",
             "waiting_computer", "waiting_dispatch_approval", "paused"].contains($0.state)
        }
    }

    private func companionApprovalsPayload() -> JSONValue {
        .array(companionApprovalObjects())
    }

    private func companionApprovalObjects() -> [JSONValue] {
        var approvals: [JSONValue] = visibleActivityRuns.compactMap { run in
            guard ["waiting_permission", "waiting_dispatch_approval"].contains(run.state)
            else { return nil }
            let kind = run.state == "waiting_permission" ? "permission" : "dispatch"
            let tool = run.sessionID.flatMap { taskWorkers[$0]?.pendingForegroundEvent?["tool"] as? String }
            return .object([
                "kind": .string(kind),
                "run_id": .string(run.id),
                "chat_id": run.sessionID.map(JSONValue.string) ?? .null,
                "title": .string(kind == "permission" ? "Action needs approval" : "Team plan is ready"),
                "detail": tool.map { .string("Allow \($0) once?") } ?? .string("Review this decision on mobile or open the Mac."),
                "decisions": kind == "permission"
                    ? .array([.string("allow_once"), .string("deny")])
                    : .array([.string("approve"), .string("cancel")]),
            ])
        }
        if planApprovalPending {
            approvals.append(.object([
                "kind": .string("plan"),
                "chat_id": .string(currentSessionID),
                "title": .string("Implementation plan is ready"),
                "detail": .string("Approve to build it, or cancel and keep the plan."),
                "decisions": .array([.string("approve"), .string("cancel")]),
            ]))
        }
        if let question = pendingUserQuestion {
            approvals.append(.object([
                "kind": .string("question"),
                "chat_id": .string(currentSessionID),
                "title": .string(question.title),
                "detail": .string(String(question.question.prefix(1_000))),
                "recommended": question.recommended.nilIfEmpty.map(JSONValue.string) ?? .null,
                // "answer" is the free-text decision: the client sends it with
                // a `text` field. Always advertised, so option-less questions
                // stay answerable from the phone.
                "decisions": .array(
                    question.options.map { .string($0.label) }
                        + [.string("answer"), .string("dismiss")]
                ),
            ]))
        }
        return approvals
    }

    private func companionWorkspaces() -> [(path: String, environment: ChatExecutionEnvironment)] {
        var seen: Set<String> = []
        var result: [(String, ChatExecutionEnvironment)] = []
        for profile in workspaceProfiles {
            let path = SessionSummary.canonicalWorkspacePath(profile.path)
            guard seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { continue }
            result.append((path, companionDefaultEnvironment(for: path)))
        }
        for session in sessions {
            guard let rawPath = session.workspacePath else { continue }
            let path = SessionSummary.canonicalWorkspacePath(rawPath)
            guard seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { continue }
            result.append((path, companionDefaultEnvironment(for: path)))
        }
        return result
    }

    private func companionDefaultEnvironment(for path: String) -> ChatExecutionEnvironment {
        guard settings.newGitChatsUseWorktree else { return .local }
        var isDirectory: ObjCBool = false
        let marker = URL(fileURLWithPath: path).appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory)
            ? .worktree : .local
    }

    private func companionWorkspaceID(_ path: String) -> String {
        String(CompanionCrypto.tokenHash(path, serviceID: "workspace").prefix(32))
    }
}
