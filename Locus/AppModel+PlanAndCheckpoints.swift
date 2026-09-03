import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Session checkpoints and rewind targets, plan requests and approval,
/// and user-question resolution.
extension AppModel {
    func createCheckpoint(title: String? = nil) {
        let fallbackTitle = blocks.last(where: { $0.kind == .user })?.text
            .components(separatedBy: .newlines)
            .first
            .map { String($0.prefix(54)) }
        let checkpoint = SessionCheckpoint(
            id: UUID(),
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? fallbackTitle?.nilIfEmpty
                ?? "Session snapshot",
            createdAt: Date(),
            blocks: blocks,
            todos: todos,
            contextFiles: contextFiles,
            workspacePath: workspacePath,
            model: selectedModel,
            activePlan: activePlan
        )
        checkpoints.insert(checkpoint, at: 0)
        checkpoints = Array(checkpoints.prefix(12))
        persistCheckpoints()
        checkpointPresented = false
        showToast("Session checkpoint created")
    }

    func restore(_ checkpoint: SessionCheckpoint) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before restoring a checkpoint")
            return
        }
        guard workspaceAccess.activateStored(path: checkpoint.workspacePath) else {
            showToast("Choose that workspace again before restoring this checkpoint")
            return
        }
        guard backend.send(["type": "new_session"]) else {
            showToast("Reconnect before restoring a checkpoint")
            return
        }
        pendingSessionReset = true
        pendingCheckpointRestore = checkpoint
        checkpointPresented = false
        showToast("Restoring checkpoint…")
    }

    func delete(_ checkpoint: SessionCheckpoint) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        persistCheckpoints()
    }

    func requestPlan(
        prompt: String = "Create a concise implementation plan for the current request and workspace."
    ) {
        guard !isBusy, !hasPendingPermission else {
            showToast("Finish the active run before creating a plan")
            return
        }
        guard isAgentOnline else {
            showToast("Reconnect the local agent to create a plan")
            return
        }
        selectedMode = .plan
        send(prompt, preservingDraftOnFailure: false)
    }

    /// Resolves the final Plan-mode decision without changing permissions.
    func resolvePlanApproval(_ decision: PlanApprovalDecision) {
        guard planApprovalPending else { return }
        switch decision {
        case .revise:
            planApprovalPending = false
            selectedMode = .plan
            drainQueuedMessages()
        case .cancel:
            planApprovalPending = false
            selectedMode = .work
            drainQueuedMessages()
        case .proceed:
            guard isAgentOnline else {
                showToast("Reconnect the local agent to implement the plan")
                return
            }
            planApprovalPending = false
            selectedMode = .work
            Task { [weak self] in
                guard let self else { return }
                send(
                    "Implement the plan you just created, in order. Keep the todo list updated as you complete each step.",
                    preservingDraftOnFailure: false,
                    requeueingOnFailure: true
                )
            }
        }
    }

    /// The chosen option's label, the typed elaboration, or both — the plain
    /// prose the model reads back as the next user message.
    nonisolated static func composedQuestionAnswer(
        option: UserQuestionOption?, freeText: String
    ) -> String? {
        var parts: [String] = []
        if let label = option?.label.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            parts.append(label)
        }
        let typed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    /// Sends the user's answer to the pending question as an ordinary user
    /// message — the turn already ended, so there is nothing to unblock.
    func resolveUserQuestion(option: UserQuestionOption?, freeText: String) {
        guard pendingUserQuestion != nil,
              let answer = Self.composedQuestionAnswer(option: option, freeText: freeText)
        else { return }
        guard isAgentOnline else {
            showToast("Reconnect the local agent to answer")
            return
        }
        pendingUserQuestion = nil
        Task { [weak self] in
            guard let self else { return }
            send(answer, preservingDraftOnFailure: false, requeueingOnFailure: true)
        }
    }

    /// Dismisses the question popup without answering; the question stays
    /// readable in the transcript and the composer takes over. A partially
    /// typed answer moves into the composer draft rather than vanishing.
    func dismissUserQuestion(keepingDraft draft: String = "") {
        guard pendingUserQuestion != nil else { return }
        pendingUserQuestion = nil
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = typed
        }
        drainQueuedMessages()
    }

    /// Return structured answers to a worker parked by `ask_question`.
    func resolveBlockingQuestion(
        _ answers: [AgentQuestionAnswer],
        action: String = "answer"
    ) {
        guard let request = pendingBlockingQuestion else { return }
        if !isUITesting {
            guard conversationBackend.send([
                "type": "question_response",
                "request_id": request.id,
                "action": action,
                "answers": answers.compactMap(encodedJSONObject),
            ]) else {
                showToast("The agent disconnected before your answer was sent")
                return
            }
        }
        pendingBlockingQuestion = nil
        drainQueuedMessages()
    }

    func cancelBlockingQuestion() {
        resolveBlockingQuestion([], action: "cancel")
    }

    func clearPendingQuestion() {
        pendingUserQuestion = nil
        capturedQuestionThisTurn = nil
        pendingBlockingQuestion = nil
    }
}
