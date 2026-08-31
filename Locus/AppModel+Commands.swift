import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Slash-command execution, rewind, permission decisions, and
/// model/provider switching.
extension AppModel {
    // MARK: - Slash commands

    func execute(_ command: SlashCommand, argument: String) {
        switch command.action {
        case .clearChat, .newSession:
            requestClearChat()
        case .setMode(let mode):
            selectedMode = mode
            showToast(mode == .ask ? "Just Chat is on" : "Switched to \(mode.title) mode")
        case .selectModel:
            selectModelMatching(argument)
        case .browseModels:
            modelLibraryPresented = true
        case .refreshModels:
            Task {
                await refreshMetadata()
                showToast("Models refreshed")
            }
        case .createCheckpoint:
            if argument.isEmpty {
                checkpointPresented = true
            } else {
                createCheckpoint(title: argument)
            }
        case .manageCheckpoints:
            checkpointPresented = true
        case .reviewChanges:
            selectInspectorTab(.changes)
        case .openPreview:
            selectInspectorTab(.preview)
        case .addContext:
            addContext()
        case .exportSession:
            exportCurrentSession()
        case .chooseWorkspace:
            chooseWorkspace()
        case .newWorkspace:
            createWorkspace()
        case .openSettings:
            settingsPresented = true
        case .setPermissionMode(let mode):
            setPermissionMode(mode)
        case .showShortcuts:
            shortcutsPresented = true
        case .showHelp:
            let help = SlashCommand.all.map(\.helpLine).joined(separator: "\n")
            blocks.append(ChatBlock(kind: .note, text: "Available commands:\n\(help)"))
        case .copyLastResponse:
            if let last = blocks.last(where: { $0.kind == .assistant && !$0.text.isEmpty }) {
                copyMessage(last.text)
            } else {
                showToast("No response to copy yet")
            }
        case .retryLastResponse:
            retryLastResponse()
        case .stopRun:
            stop()
        case .compact:
            sendRaw("/compact")
        case .remember:
            if argument.isEmpty {
                settingsPage = .knowledge
                settingsPresented = true
            } else {
                rememberConfirmationText = argument
            }
        case .setThinkingVisibility:
            setThinkingVisibility(argument)
        }
    }

    private func selectModelMatching(_ argument: String) {
        guard !argument.isEmpty else {
            let installed = models.map(\.name).joined(separator: "\n")
            blocks.append(ChatBlock(
                kind: .note,
                text: installed.isEmpty
                    ? "No Ollama models installed yet — use /models to browse Hugging Face."
                    : "Installed models:\n\(installed)\n\nUse /model <name> to switch."
            ))
            return
        }
        let lower = argument.lowercased()
        let match = models.first { $0.name.caseInsensitiveCompare(argument) == .orderedSame }
            ?? models.first { $0.name.lowercased().contains(lower) }
        if let match {
            selectModel(match.name)
        } else {
            showToast("No installed model matches “\(argument)”")
        }
    }

    private func setThinkingVisibility(_ argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            let options = ThinkingVisibility.allCases
                .map { "/thinking \($0.rawValue) — \($0.detail)" }
                .joined(separator: "\n")
            blocks.append(ChatBlock(
                kind: .note,
                text: "Thinking is \(thinkingVisibility.title.lowercased()).\n\(options)"
            ))
            return
        }
        guard let visibility = ThinkingVisibility(rawValue: trimmed) else {
            showToast("Use /thinking hidden, collapsed, or expanded")
            return
        }
        thinkingVisibility = visibility
        showToast("Thinking \(visibility.title.lowercased())")
    }

    // MARK: - Rewind

    func canRewind(to block: ChatBlock) -> Bool {
        block.kind == .user && !isBusy && !hasPendingPermission
    }

    /// Restores the conversation to the state just before a user message and
    /// places that message back in the composer for editing — Claude Code's
    /// per-message rewind, built on the checkpoint mechanism.
    func rewind(to block: ChatBlock) {
        guard canRewind(to: block),
              let index = blocks.firstIndex(where: { $0.id == block.id })
        else { return }
        let firstLine = block.text
            .components(separatedBy: .newlines)
            .first.map { String($0.prefix(42)) } ?? "message"
        let checkpoint = SessionCheckpoint(
            id: UUID(),
            title: "Rewind point — \(firstLine)",
            createdAt: Date(),
            blocks: Array(blocks.prefix(upTo: index)),
            todos: [],
            contextFiles: contextFiles,
            workspacePath: workspacePath,
            model: selectedModel,
            activePlan: nil
        )
        pendingRewindDraft = block.text
        restore(checkpoint)
    }

    func decide(requestID: String, decision: String) {
        // UI tests drive the prompt against a dead socket; applying the
        // decision locally is what lets the panel advance and dismiss.
        if !isUITesting {
            guard conversationBackend.send([
                "type": "permission_decision",
                "request_id": requestID,
                "decision": decision,
            ]) else {
                showToast("The agent disconnected before the decision was sent")
                return
            }
        }
        if let index = blocks.lastIndex(where: { $0.tool?.requestID == requestID }) {
            blocks[index].tool?.status = decision == "deny" ? .denied : .running
        }
        if let runtime = taskWorkers[currentSessionID] {
            runtime.executionState = .running
            updateBackgroundChatState(runtime)
        }
        if orchestrationRunID != nil {
            orchestrationState = .running
            updateTaskConversation(state: .running, event: [:])
        }
    }

    func selectModel(_ model: String) {
        rememberManualModelRoute(accountID: activeAccount?.id, model: model)
        if isBusy {
            pendingProviderSwitch = (activeAccount?.id, model)
            showToast("Switching to \(model) after this turn")
            return
        }
        guard backend.send(["type": "set_model", "model": model]) else {
            showToast("Reconnect before switching models")
            return
        }
        showToast("Switching to \(model)")
    }

    /// Routes the session to a model, switching providers when the model comes
    /// from a different source than the one in use.
    ///
    /// `account` nil means local Ollama. Switching providers replaces the
    /// agent's client, which it refuses to do mid-turn — so a switch requested
    /// during a run is held and applied when the turn finishes.
    func selectModel(account: ProviderAccount?, model: String) {
        rememberManualModelRoute(accountID: account?.id, model: model)
        let sameSource = account?.id.uuidString == settings.activeAccountID
        guard !sameSource else {
            if let account {
                rememberPreferredModel(model, for: account)
                // The window belongs to the model, not to the account. Sending
                // only `set_model` left the agent budgeting against the model we
                // just switched away from: a Claude account moved from a
                // 1,000,000-token model to a 200,000-token one kept metering
                // against 1,000,000 and would not compact until five times over
                // the real window, failing every request past it.
                Task { [weak self] in
                    await self?.applyProvider(announce: false)
                    // After the provider call, so the transcript records the
                    // switch against the model the agent has actually adopted.
                    self?.selectModel(model)
                }
            } else {
                selectModel(model)
            }
            return
        }
        if let account, !account.isCredentialReady {
            showToast("Add an API key for \(account.displayName) in Settings")
            settingsPresented = true
            return
        }
        guard !isBusy else {
            pendingProviderSwitch = (account?.id, model)
            showToast("Switching to \(account?.displayName ?? "local Ollama") after this turn")
            return
        }
        applyProviderSwitch(accountID: account?.id, model: model)
    }

    /// A provider switch that arrived mid-turn, applied once the agent is idle.

    func applyPendingProviderSwitchIfNeeded() {
        guard let pending = pendingProviderSwitch else { return }
        pendingProviderSwitch = nil
        applyProviderSwitch(accountID: pending.accountID, model: pending.model)
    }

    func applyProviderSwitch(accountID: UUID?, model: String) {
        // The route is committed before the agent has accepted it, because the
        // request body is built from these fields.
        let previousAccountID = settings.activeAccountID
        let previousProvider = settings.provider
        if let accountID, let account = providerAccounts.first(where: { $0.id == accountID }) {
            rememberPreferredModel(model, for: account)
            settings.activeAccountID = accountID.uuidString
            settings.provider = .remote
        } else {
            settings.activeAccountID = nil
            settings.provider = .ollama
        }
        persistSettings()
        Task {
            guard await applyProvider() else {
                // The agent kept the provider it had. Leaving the new account
                // committed would leave the app pointing at an account that
                // never connected while every turn still runs on the old
                // route — visible as an account paired with another
                // provider's model.
                settings.activeAccountID = previousAccountID
                settings.provider = previousProvider
                persistSettings()
                return
            }
            // The remote provider adopts its configured model as it connects;
            // the local runtime keeps whatever it had, so name it explicitly.
            if accountID == nil, !model.isEmpty, model != selectedModel {
                selectModel(model)
            }
            persistCurrentWorkspaceProfile()
        }
    }

    private func rememberPreferredModel(_ model: String, for account: ProviderAccount) {
        guard modelBelongsToAccount(model, account: account) else { return }
        guard let index = providerAccounts.firstIndex(where: { $0.id == account.id }),
              providerAccounts[index].preferredModel != model
        else { return }
        providerAccounts[index].preferredModel = model
        providerAccountsModel.persistProviderAccounts()
    }

    func modelBelongsToAccount(_ model: String, account: ProviderAccount) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if account.kind != .custom {
            return ProviderModelFilter.matches(kind: account.kind, name: trimmed)
        }
        if case .connected = accountStatus[account.id],
           let reported = accountModels[account.id], !reported.isEmpty
        {
            return reported.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
        let routed = agentProfiles.filter { $0.route.accountID == account.id }.map(\.model)
        return routed.isEmpty || routed.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
