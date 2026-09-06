import AppKit
import Foundation

extension AppModel {
    func configureLibraryFeatures() {
        library.configure(backend: backend)
        outputsLibrary.configure(emitter: sessionOverview, enabled: persistenceEnabled)
        outputsLibrary.activate(workspace: workspacePath)
    }

    func openLibrary(tab: WorkspaceLibraryTab = .documents) {
        library.tab = tab
        library.isPresented = true
        library.activate(workspace: workspacePath)
        outputsLibrary.clearOriginFilter()
        outputsLibrary.activate(workspace: workspacePath)
    }

    func openOutputsLibrary(workspace: String, sessionID: String? = nil, runID: String? = nil) {
        library.tab = .outputs
        library.isPresented = true
        library.activate(workspace: workspace)
        outputsLibrary.activate(workspace: workspace)
        outputsLibrary.filterOrigin(sessionID: sessionID, runID: runID)
    }

    func openLibraryOutput(itemID: String, versionID: String? = nil, workspace: String) {
        openOutputsLibrary(workspace: workspace)
        outputsLibrary.open(itemID: itemID, versionID: versionID)
    }

    func openOutputSourceChat(_ sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            showToast("The original chat is no longer available")
            return
        }
        library.isPresented = false
        resume(session)
    }

    func reviseLibraryOutput(_ output: LibraryOutput, version: OutputVersion) {
        guard !isBusy, !pendingSessionReset else {
            showToast("Wait for the active task to finish before preparing a revision")
            return
        }
        guard draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chatAttachments.isEmpty else {
            showToast("Save or send the current draft before preparing a revision")
            return
        }
        Task {
            guard let snapshot = await outputsLibrary.store.versionURL(output, version: version) else {
                showToast("This version has no saved file")
                return
            }
            do {
                let attachment: ChatAttachment
                if ["pdf", "docx", "xlsx", "csv", "tsv"].contains(snapshot.pathExtension.lowercased()) {
                    let extracted = try await library.extractTemporary(snapshot, workspace: output.workspace)
                    let text = extracted.segments.map { "[\($0.locator.label)]\n\($0.text)" }.joined(separator: "\n\n")
                    attachment = ChatAttachment(url: snapshot, kind: .text, textContent: text, overrideName: "\(output.title) — \(version.label)")
                } else {
                    let result = await Task.detached(priority: .userInitiated) {
                        ChatAttachmentLoader.readChatAttachments([snapshot], excluding: [])
                    }.value
                    guard let loaded = result.attachments.first else {
                        throw OutputsLibraryStore.StoreError(result.notice ?? "This output cannot be attached for revision")
                    }
                    attachment = loaded
                }
                let oldSession = currentSessionID
                guard !isBusy, !pendingSessionReset, draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      chatAttachments.isEmpty else { throw OutputsLibraryStore.StoreError("Finish the current task or draft before preparing a revision") }
                newSession(in: output.workspace, environment: .local)
                for _ in 0..<150 {
                    if !pendingSessionReset { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !pendingSessionReset, currentSessionID != oldSession,
                      OutputsLibraryStore.canonical(workspacePath) == output.workspace else {
                    throw OutputsLibraryStore.StoreError("Could not prepare a revision chat. Try again.")
                }
                chatAttachments = [attachment]
                draftText = "Revise \(output.title) using the attached \(version.label.lowercased()) as the reference.\n\nRequested changes: \n\nSave the revised result to \(output.target). The attached library snapshot is read-only; create or update the destination file."
                library.isPresented = false
                showToast("Revision draft ready · destination: \(output.target)")
            } catch { showToast(error.localizedDescription) }
        }
    }
}
