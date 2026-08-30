import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Per-workspace memory: profile apply and route restoration on switch,
/// debounced persistence, and the UserDefaults writers for profiles,
/// settings, and checkpoints.
extension AppModel {
    func applyWorkspaceProfileIfNeeded(for info: SessionInfo) {
        let path = SessionSummary.canonicalWorkspacePath(info.cwd)
        guard appliedWorkspacePath != path || pendingWorkspacePath == path else { return }
        let changedWorkspace = appliedWorkspacePath != nil && appliedWorkspacePath != path
        appliedWorkspacePath = path
        pendingWorkspacePath = nil
        expandedWorkspaceIDs.insert(path)
        persistExpandedWorkspaces()
        if changedWorkspace {
            flushPendingTokens()
            blocks = []
            todos = []
            activePlan = nil
            planApprovalPending = false
            clearPendingQuestion()
            restoredTranscriptContext = nil
        }
        soloSwarmEnabled = true
        if let profile = workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            draftText = profile.draft
            soloSwarmEnabled = true
            selectedMode = profile.mode
            settings.previewURL = profile.previewURL
            contextFiles = profile.contextFiles
            applyProfileRoute(profile, currentModel: info.model)
            Task { await refreshContextFiles() }
        }
        touchWorkspaceProfile(path)
        gitWorkspace.refreshBranch()
        workspaceFiles.refresh(force: true)
    }

    /// Restores the model a workspace was last used with, through the account
    /// it belonged to.
    private func applyProfileRoute(_ profile: WorkspaceProfile, currentModel: String) {
        guard !profile.model.isEmpty else { return }
        guard profile.accountID != settings.activeAccountID || profile.model != currentModel
        else { return }
        if let accountID = profile.accountID {
            // An account deleted since this workspace was last open leaves the
            // session where it is rather than routing somewhere unintended.
            guard let account = providerAccounts.first(where: { $0.id.uuidString == accountID })
            else { return }
            selectModel(account: account, model: profile.model)
        } else if settings.activeAccountID == nil {
            // Still on the local runtime: only the model has to change, and
            // only if it is actually installed.
            if localModels.contains(where: { $0.name == profile.model }) {
                backend.send(["type": "set_model", "model": profile.model])
            }
        } else {
            // A model deliberately removed from Locus must not return merely
            // because an older workspace profile still remembers it.
            guard localModels.contains(where: { $0.name == profile.model }) else { return }
            selectModel(account: nil, model: profile.model)
        }
    }

    func touchWorkspaceProfile(_ path: String) {
        let path = SessionSummary.canonicalWorkspacePath(path)
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            workspaceProfiles[index].lastOpened = Date()
        } else {
            let route = stableWorkspaceRoute(for: path)
            workspaceProfiles.append(
                WorkspaceProfile(
                    path: path,
                    lastOpened: Date(),
                    model: route.model,
                    accountID: route.accountID,
                    mode: selectedMode,
                    previewURL: settings.previewURL,
                    contextFiles: contextFiles,
                    draft: draftText,
                    soloSwarmEnabled: soloSwarmEnabled
                )
            )
        }
        workspaceProfiles.sort { $0.lastOpened > $1.lastOpened }
        persistWorkspaceProfiles()
    }

    func scheduleSettingsPersistence() {
        guard persistenceEnabled else { return }
        settingsPersistenceTask?.cancel()
        settingsPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.persistSettings()
        }
    }

    func scheduleWorkspacePersistence() {
        guard persistenceEnabled else { return }
        profilePersistenceTask?.cancel()
        profilePersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.persistCurrentWorkspaceProfile()
        }
    }

    func persistCurrentWorkspaceProfile() {
        // Before the agent reports a session, workspacePath falls back to the
        // home directory — which must never be recorded as a real workspace.
        guard sessionInfo != nil else { return }
        let path = workspacePath
        let route = stableWorkspaceRoute(for: path)
        let profile = WorkspaceProfile(
            path: path,
            lastOpened: Date(),
            model: route.model,
            accountID: route.accountID,
            mode: selectedMode,
            previewURL: settings.previewURL,
            contextFiles: contextFiles,
            draft: draftText,
            reasoningEffort: pendingReasoningEffort ?? workspaceProfiles.first(where: {
                SessionSummary.canonicalWorkspacePath($0.path) == path
            })?.reasoningEffort,
            soloSwarmEnabled: soloSwarmEnabled,
            landingCheckCommands: workspaceProfiles.first(where: {
                SessionSummary.canonicalWorkspacePath($0.path) == path
            })?.landingCheckCommands
        )
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        }) {
            workspaceProfiles[index] = profile
        } else {
            workspaceProfiles.append(profile)
        }
        workspaceProfiles.sort { $0.lastOpened > $1.lastOpened }
        persistWorkspaceProfiles()
    }

    /// Team jobs temporarily replace AgentCore's provider and model. Persist
    /// the user's solo route instead of pairing the last team member's model
    /// with an unrelated account and contaminating that account's picker.
    func stableWorkspaceRoute(for path: String) -> (model: String, accountID: String?) {  // internal(for: AppModel extension files)
        if settings.automaticModelRoutingEnabled || isRestoringManualModelRoute {
            let fallback = settings.modelRouterFallbackModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                if let accountID = settings.modelRouterFallbackAccountID,
                   providerAccounts.contains(where: { $0.id.uuidString == accountID })
                {
                    return (fallback, accountID)
                }
                if settings.modelRouterFallbackAccountID == nil,
                   localModels.contains(where: {
                       $0.name.caseInsensitiveCompare(fallback) == .orderedSame
                   })
                {
                    return (fallback, nil)
                }
            }
        }
        if let account = activeAccount {
            return (account.preferredModel, account.id.uuidString)
        }
        guard teamModeEnabled || orchestrationRunID != nil else {
            return (selectedModel, nil)
        }
        if let existing = workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path && $0.accountID == nil
        }), !existing.model.isEmpty {
            return (existing.model, nil)
        }
        let installed = localModels.first(where: { $0.name == selectedModel })?.name
            ?? localModels.first?.name
            ?? ""
        return (installed, nil)
    }

    func persistWorkspaceProfiles() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(workspaceProfiles) {
            UserDefaults.standard.set(data, forKey: "Locus.workspaceProfiles")
        }
    }

    func recordPrompt(_ text: String) {
        promptHistory.removeAll { $0 == text }
        promptHistory.insert(text, at: 0)
        promptHistory = Array(promptHistory.prefix(50))
        promptHistoryCursor = nil
        if persistenceEnabled {
            UserDefaults.standard.set(promptHistory, forKey: "Locus.promptHistory")
        }
    }

    func rebalanceContextBudget() {
        var used = 0
        var excluded = 0
        for index in contextFiles.indices where contextFiles[index].isIncluded {
            guard contextFiles[index].isAvailable else {
                contextFiles[index].isIncluded = false
                continue
            }
            let tokens = contextFiles[index].estimatedTokens
            if used + tokens > contextBudgetTokens {
                contextFiles[index].isIncluded = false
                excluded += 1
            } else {
                used += tokens
            }
        }
        if excluded > 0 {
            contextNotice = "\(excluded) file\(excluded == 1 ? "" : "s") excluded to preserve model response space."
        } else if used >= Int(Double(contextBudgetTokens) * 0.8) {
            contextNotice = "Context pack is near its \(contextBudgetTokens.formatted()) token budget."
        }
    }

    func persistExpandedWorkspaces() {
        guard persistenceEnabled else { return }
        UserDefaults.standard.set(
            expandedWorkspaceIDs.sorted(),
            forKey: "Locus.expandedWorkspaces"
        )
    }

    func persistSettings() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "Locus.settings")
        }
    }

    func persistCheckpoints() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(checkpoints) {
            UserDefaults.standard.set(data, forKey: "Locus.checkpoints")
        }
    }
}
