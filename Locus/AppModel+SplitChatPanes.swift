import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Two-pane split chat: opening, focusing, and closing panes, per-pane
/// drafts and blocks, foreground snapshotting, and restoration — plus the
/// chat export entry points that share the pane machinery.
extension AppModel {
    // MARK: - Split chat panes

    var splitViewActive: Bool { chatSplitRestoration.isSplit }

    func chatPaneState(for pane: ChatPaneID) -> ChatPaneState {
        pane == .primary ? primaryChatPaneState : secondaryChatPaneState
    }

    func splitSessionID(for pane: ChatPaneID) -> String? {
        chatSplitRestoration.sessionID(for: pane)
    }

    func paneBlocks(for sessionID: String) -> [ChatBlock] {
        if sessionID == currentSessionID { return blocks }
        var snapshot = splitPaneBlocks[sessionID] ?? []
        if let runtime = taskWorkers[sessionID],
           let streamingID = runtime.streamingBlockID
        {
            snapshot.removeAll { $0.id == streamingID || $0.isStreaming }
            snapshot.append(ChatBlock(
                id: streamingID,
                kind: .assistant,
                text: runtime.streamingText,
                reasoningText: runtime.streamingReasoning.nilIfEmpty,
                isStreaming: true
            ))
        }
        return snapshot
    }

    func paneDraft(for sessionID: String) -> String {
        if sessionID == currentSessionID { return draftText }
        return splitPaneDrafts[sessionID] ?? ""
    }

    func setPaneDraft(_ value: String, for sessionID: String) {
        if sessionID == currentSessionID {
            draftText = value
        } else {
            splitPaneDrafts[sessionID] = value
        }
        paneState(containing: sessionID)?.draft = value
    }

    func toggleSplitView() {
        if chatSplitRestoration.isSplit {
            closeChatPane(.secondary)
            return
        }
        guard let session = sessions.first(where: {
            !$0.isArchived && $0.id != currentSessionID
        }) else {
            showToast("Open another saved chat before splitting the view")
            return
        }
        openInOtherPane(session)
    }

    func openInOtherPane(_ session: SessionSummary) {
        guard session.id != currentSessionID else {
            showToast("That chat is already open in this pane")
            return
        }
        if !chatSplitRestoration.isSplit {
            chatSplitRestoration.primarySessionID = currentSessionID.nilIfEmpty
        }
        let other = chatSplitRestoration.focusedPane.other
        if other == .primary {
            chatSplitRestoration.primarySessionID = session.id
        } else {
            chatSplitRestoration.secondarySessionID = session.id
        }
        chatSplitRestoration.focusedPane = other
        persistChatSplitRestoration()
        refreshSplitPane(session.id)
        resume(session)
    }

    func open(_ session: SessionSummary, in pane: ChatPaneID) {
        if !chatSplitRestoration.isSplit {
            openInOtherPane(session)
            return
        }
        if chatSplitRestoration.sessionID(for: pane) == session.id {
            focusChatPane(pane)
            return
        }
        if pane == .primary {
            chatSplitRestoration.primarySessionID = session.id
        } else {
            chatSplitRestoration.secondarySessionID = session.id
        }
        chatSplitRestoration.focusedPane = pane
        persistChatSplitRestoration()
        resume(session)
    }

    func focusChatPane(_ pane: ChatPaneID) {
        guard let sessionID = splitSessionID(for: pane), sessionID != currentSessionID,
              let session = sessions.first(where: { $0.id == sessionID })
        else {
            if splitSessionID(for: pane) != nil {
                chatSplitRestoration.focusedPane = pane
                persistChatSplitRestoration()
            }
            return
        }
        chatSplitRestoration.focusedPane = pane
        persistChatSplitRestoration()
        resume(session)
    }

    func closeChatPane(_ pane: ChatPaneID) {
        guard chatSplitRestoration.isSplit else { return }
        captureForegroundPane()
        let remainingPane = pane.other
        guard let remainingSessionID = splitSessionID(for: remainingPane) else { return }
        let shouldActivate = currentSessionID != remainingSessionID
        chatSplitRestoration = ChatSplitRestoration(
            primarySessionID: remainingSessionID,
            secondarySessionID: nil,
            focusedPane: .primary,
            dividerRatio: chatSplitRestoration.dividerRatio
        )
        persistChatSplitRestoration()
        if shouldActivate,
           let remaining = sessions.first(where: { $0.id == remainingSessionID })
        {
            resume(remaining)
        }
    }

    func setSplitDividerRatio(_ value: Double) {
        chatSplitRestoration.dividerRatio = min(max(value, 0.28), 0.72)
        persistChatSplitRestoration()
    }

    func submitDraft(in pane: ChatPaneID) {
        guard let sessionID = splitSessionID(for: pane) else { return }
        let text = paneDraft(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        setPaneDraft(text, for: sessionID)
        if currentSessionID == sessionID {
            submitDraft()
            return
        }
        focusChatPane(pane)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<100 {
                if currentSessionID == sessionID,
                   sessionInfo?.sessionID == sessionID
                {
                    draftText = text
                    submitDraft()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            showToast("That pane is still reconnecting — your draft is preserved")
        }
    }

    func refreshSplitPane(_ sessionID: String) {
        guard sessionID != currentSessionID else {
            splitPaneBlocks[sessionID] = blocks
            return
        }
        Task {
            guard let detail = try? await backend.get(
                "/api/sessions/\(sessionID)",
                as: SessionDetailResponse.self
            ) else { return }
            splitPaneBlocks[sessionID] = ChatTranscriptBuilder.blocks(from: detail.messages)
            paneState(containing: sessionID)?.blocks = splitPaneBlocks[sessionID] ?? []
        }
    }

    func prepareSplitSelection(_ sessionID: String) {
        guard sessionID != currentSessionID else { return }
        captureForegroundPane()
        if !chatSplitRestoration.isSplit {
            chatSplitRestoration.primarySessionID = sessionID
            chatSplitRestoration.secondarySessionID = nil
            chatSplitRestoration.focusedPane = .primary
        } else if chatSplitRestoration.primarySessionID == sessionID {
            chatSplitRestoration.focusedPane = .primary
        } else if chatSplitRestoration.secondarySessionID == sessionID {
            chatSplitRestoration.focusedPane = .secondary
        } else if chatSplitRestoration.focusedPane == .primary {
            chatSplitRestoration.primarySessionID = sessionID
        } else {
            chatSplitRestoration.secondarySessionID = sessionID
        }
        restorePanePreferences(for: sessionID)
        persistChatSplitRestoration()
    }

    private func captureForegroundPane() {
        guard !currentSessionID.isEmpty else { return }
        splitPaneBlocks[currentSessionID] = blocks
        splitPaneDrafts[currentSessionID] = draftText
        splitPaneAttachments[currentSessionID] = chatAttachments
        splitPaneModes[currentSessionID] = selectedMode
        splitPaneTeams[currentSessionID] = selectedAgentTeamID
        splitPaneSoloRouting[currentSessionID] = soloSwarmEnabled
        splitPaneSearchQueries[currentSessionID] = transcriptSearchQuery
        if let state = paneState(containing: currentSessionID) {
            state.blocks = blocks
            state.draft = draftText
            state.attachments = chatAttachments
            state.mode = selectedMode
            state.selectedTeamID = selectedAgentTeamID
            state.soloRouting = soloSwarmEnabled
            state.transcriptSearchQuery = transcriptSearchQuery
            state.contextFiles = contextFiles
            state.queuedMessages = queuedMessages
            state.selectedRouteModel = selectedModel
            state.runStatus = orchestrationState
            state.isBusy = isBusy
            state.hasPendingPermission = hasPendingPermission
        }
    }

    private func restorePanePreferences(for sessionID: String) {
        let state = paneState(containing: sessionID)
        draftText = state?.draft ?? splitPaneDrafts[sessionID] ?? ""
        chatAttachments = state?.attachments ?? splitPaneAttachments[sessionID] ?? []
        contextFiles = state?.contextFiles ?? []
        queuedMessages = state?.queuedMessages ?? []
        if let mode = state?.mode ?? splitPaneModes[sessionID] { selectedMode = mode }
        selectedAgentTeamID = state?.selectedTeamID ?? splitPaneTeams[sessionID] ?? nil
        soloSwarmEnabled = selectedAgentTeamID == nil
        if let query = state?.transcriptSearchQuery { transcriptSearchQuery = query }
    }

    func paneState(containing sessionID: String) -> ChatPaneState? {
        if primaryChatPaneState.sessionID == sessionID { return primaryChatPaneState }
        if secondaryChatPaneState.sessionID == sessionID { return secondaryChatPaneState }
        return nil
    }

    private func persistChatSplitRestoration() {
        assign(primaryChatPaneState, to: chatSplitRestoration.primarySessionID)
        assign(secondaryChatPaneState, to: chatSplitRestoration.secondarySessionID)
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(chatSplitRestoration)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.splitRestorationKey)
    }

    private func assign(_ state: ChatPaneState, to sessionID: String?) {
        guard state.sessionID != sessionID else { return }
        state.sessionID = sessionID
        guard let sessionID else {
            state.blocks = []
            state.draft = ""
            state.attachments = []
            return
        }
        state.blocks = splitPaneBlocks[sessionID] ?? []
        state.draft = splitPaneDrafts[sessionID] ?? ""
        state.attachments = splitPaneAttachments[sessionID] ?? []
        state.mode = splitPaneModes[sessionID] ?? .work
        state.selectedTeamID = splitPaneTeams[sessionID] ?? nil
        state.soloRouting = splitPaneSoloRouting[sessionID] ?? false
        state.transcriptSearchQuery = splitPaneSearchQueries[sessionID] ?? ""
    }

    func reconcileChatSplitRestoration() {
        let existing = Set(sessions.map(\.id))
        var restoration = chatSplitRestoration
        if let primary = restoration.primarySessionID, !existing.contains(primary) {
            restoration.primarySessionID = nil
        }
        if let secondary = restoration.secondarySessionID, !existing.contains(secondary) {
            restoration.secondarySessionID = nil
        }
        if restoration.primarySessionID == nil, let secondary = restoration.secondarySessionID {
            restoration.primarySessionID = secondary
            restoration.secondarySessionID = nil
            restoration.focusedPane = .primary
        }
        if restoration.primarySessionID == restoration.secondarySessionID {
            restoration.secondarySessionID = nil
            restoration.focusedPane = .primary
        }
        if restoration.primarySessionID == nil {
            restoration.primarySessionID = currentSessionID.nilIfEmpty
        }
        chatSplitRestoration = restoration
        persistChatSplitRestoration()
        if let secondary = restoration.secondarySessionID {
            refreshSplitPane(secondary)
        }
        if let primary = restoration.primarySessionID, primary != currentSessionID {
            refreshSplitPane(primary)
        }
        if !didRestoreChatSplit {
            didRestoreChatSplit = true
            if let focusedID = restoration.sessionID(for: restoration.focusedPane),
               focusedID != currentSessionID,
               let focused = sessions.first(where: { $0.id == focusedID })
            {
                resume(focused)
            }
        }
    }

    func exportCurrentSession(format: ChatExportFormat = .markdown) {
        guard let session = sessions.first(where: { $0.id == currentSessionID }) else {
            showToast("Send a message first — there is no saved session to export yet")
            return
        }
        exportSession(session, format: format)
    }

    func exportSession(_ session: SessionSummary, format: ChatExportFormat = .markdown) {
        Task {
            do {
                let panel = NSSavePanel()
                panel.title = "Export Locus Session"
                panel.nameFieldStringValue = "\(ChatTranscriptBuilder.safeFilename(session.displayTitle)).\(format.pathExtension)"
                panel.allowedContentTypes = switch format {
                case .pdf: [.pdf]
                case .markdown: [UTType(filenameExtension: "md") ?? .plainText]
                case .plainText: [.plainText]
                }
                let accessory = ChatExportAccessoryView(frame: .zero)
                panel.accessoryView = accessory
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let options = accessory.options
                let document = try await backend.get(
                    "/api/sessions/\(session.id)/export-data",
                    query: [
                        URLQueryItem(
                            name: "include_reasoning",
                            value: options.includeReasoning ? "true" : "false"
                        ),
                        URLQueryItem(
                            name: "include_tool_details",
                            value: options.includeToolDetails ? "true" : "false"
                        ),
                        URLQueryItem(
                            name: "include_attachments",
                            value: options.includeAttachments ? "true" : "false"
                        ),
                    ],
                    timeout: 60,
                    as: ChatExportDocument.self
                )
                try ChatExportRenderer.write(document, format: format, to: url)
                showToast("Session exported as \(format.title)")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }
}
