import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Sidebar chat organization: rename, pin, nested folders with move and
/// reorder, duplication, archive, delete with undo, and folder expansion.
extension AppModel {
    func renameSession(_ session: SessionSummary, title: String) {
        updateSession(session, body: ["title": title], success: "Session renamed")
    }

    func togglePin(_ session: SessionSummary) {
        updateSession(session, body: ["pinned": !session.isPinned], success: session.isPinned ? "Session unpinned" : "Session pinned")
    }

    func createChatFolder(in workspace: String, name: String, parentID: String? = nil) {
        var body: [String: Any] = ["workspace": workspace, "name": name]
        if let parentID { body["parent_id"] = parentID }
        Task {
            do {
                let response = try await backend.post(
                    "/api/chat-folders", body: body, as: ChatFolderMutationResponse.self
                )
                chatFolders.append(response.folder)
                expandedChatFolderIDs.insert(response.folder.id)
                persistExpandedChatFolders()
                showToast("Folder created")
            } catch {
                showToast("Could not create folder: \(error.localizedDescription)")
            }
        }
    }

    func renameChatFolder(_ folder: ChatFolderRecord, name: String) {
        Task {
            do {
                let response = try await backend.patch(
                    "/api/chat-folders/\(folder.id)",
                    body: ["name": name],
                    as: ChatFolderMutationResponse.self
                )
                if let index = chatFolders.firstIndex(where: { $0.id == folder.id }) {
                    chatFolders[index] = response.folder
                }
                showToast("Folder renamed")
            } catch {
                showToast("Could not rename folder: \(error.localizedDescription)")
            }
        }
    }

    func deleteChatFolder(_ folder: ChatFolderRecord) {
        Task {
            do {
                let _: ChatFolderDeleteResponse = try await backend.delete(
                    "/api/chat-folders/\(folder.id)", as: ChatFolderDeleteResponse.self
                )
                await refreshChatOrganization()
                showToast("Folder removed — chats kept")
            } catch {
                showToast("Could not remove folder: \(error.localizedDescription)")
            }
        }
    }

    func moveChat(_ session: SessionSummary, to folderID: String?, index: Int? = nil) {
        var body: [String: Any] = ["folder_id": folderID ?? NSNull()]
        if let index { body["index"] = index }
        Task {
            do {
                let response = try await backend.patch(
                    "/api/sessions/\(session.id)/organization",
                    body: body,
                    as: SessionOrganizationResponse.self
                )
                if let position = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[position] = session.withOrganization(
                        folderID: response.placement.folderID,
                        sortOrder: response.placement.order
                    )
                }
                await refreshMetadata()
                showToast("Chat moved")
            } catch {
                showToast("Could not move chat: \(error.localizedDescription)")
            }
        }
    }

    func moveChatFolder(
        _ folder: ChatFolderRecord, to parentID: String?, index: Int? = nil
    ) {
        var body: [String: Any] = ["parent_id": parentID ?? NSNull()]
        if let index { body["index"] = index }
        Task {
            do {
                let response = try await backend.patch(
                    "/api/chat-folders/\(folder.id)",
                    body: body,
                    as: ChatFolderMutationResponse.self
                )
                if let position = chatFolders.firstIndex(where: { $0.id == folder.id }) {
                    chatFolders[position] = response.folder
                }
                await refreshChatOrganization()
                showToast("Folder moved")
            } catch {
                showToast("Could not move folder: \(error.localizedDescription)")
            }
        }
    }

    func canMoveChatFolder(_ folder: ChatFolderRecord, into target: ChatFolderRecord) -> Bool {
        guard folder.id != target.id,
              SessionSummary.canonicalWorkspacePath(folder.workspace)
                == SessionSummary.canonicalWorkspacePath(target.workspace)
        else { return false }
        var cursor: ChatFolderRecord? = target
        while let current = cursor {
            if current.id == folder.id { return false }
            cursor = current.parentID.flatMap { parentID in
                chatFolders.first(where: { $0.id == parentID })
            }
        }
        return true
    }

    func reorderChatFolder(_ folder: ChatFolderRecord, offset: Int) {
        let siblings = chatFolders.filter {
            SessionSummary.canonicalWorkspacePath($0.workspace)
                == SessionSummary.canonicalWorkspacePath(folder.workspace)
                && $0.parentID == folder.parentID
        }.sorted { $0.order < $1.order }
        guard let current = siblings.firstIndex(where: { $0.id == folder.id }) else { return }
        let target = min(max(current + offset, 0), max(siblings.count - 1, 0))
        guard target != current else { return }
        moveChatFolder(folder, to: folder.parentID, index: target)
    }

    func reorderChat(_ session: SessionSummary, offset: Int) {
        let siblings = sessions.filter {
            $0.workspacePath == session.workspacePath
                && $0.folderID == session.folderID
                && $0.isPinned == session.isPinned
                && $0.isArchived == session.isArchived
        }.sorted {
            if $0.sortOrder != $1.sortOrder {
                return ($0.sortOrder ?? .max) < ($1.sortOrder ?? .max)
            }
            return $0.mtime > $1.mtime
        }
        guard let current = siblings.firstIndex(where: { $0.id == session.id }) else { return }
        let target = min(max(current + offset, 0), max(siblings.count - 1, 0))
        guard target != current else { return }
        moveChat(session, to: session.folderID, index: target)
    }

    func duplicateSession(_ session: SessionSummary, withWorktree: Bool = false) {
        guard !chatHasActiveRun(session) else {
            showToast("Wait for this chat to stop before duplicating it")
            return
        }
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/\(session.id)/duplicate",
                    body: ["mode": withWorktree ? "worktree" : "conversation"],
                    timeout: withWorktree ? 120 : 20,
                    as: DuplicateSessionResponse.self
                )
                await refreshMetadata()
                if let copy = sessions.first(where: { $0.id == response.session.id }) {
                    resume(copy)
                }
                showToast(withWorktree ? "Chat and worktree duplicated" : "Chat duplicated")
            } catch {
                showToast("Could not duplicate chat: \(error.localizedDescription)")
            }
        }
    }

    var expandedChatFolderIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "Locus.expandedChatFolders") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "Locus.expandedChatFolders") }
    }

    func isChatFolderExpanded(_ id: String) -> Bool {
        expandedChatFolderIDs.contains(id)
    }

    func setChatFolderExpanded(_ id: String, expanded: Bool) {
        var values = expandedChatFolderIDs
        if expanded { values.insert(id) } else { values.remove(id) }
        expandedChatFolderIDs = values
    }

    private func persistExpandedChatFolders() {
        expandedChatFolderIDs = expandedChatFolderIDs
    }

    private func refreshChatOrganization() async {
        if let response = try? await backend.get(
            "/api/chat-folders", as: ChatFoldersResponse.self
        ) {
            chatFolders = response.folders
        }
        let suffix = showArchivedSessions ? "?include_archived=true&limit=500" : "?limit=500"
        if let response = try? await backend.get(
            "/api/sessions\(suffix)", as: SessionsResponse.self
        ) {
            sessions = response.sessions
            reconcileChatSplitRestoration()
        }
    }

    func archive(_ session: SessionSummary) {
        guard session.id != currentSessionID else {
            showToast("Start a new chat before archiving the active session")
            return
        }
        guard !chatHasActiveRun(session) else {
            showToast("Wait for this chat to stop before archiving it")
            return
        }
        updateSession(session, body: ["archived": !session.isArchived], success: session.isArchived ? "Session restored" : "Session archived")
    }

    func deleteChat(_ session: SessionSummary) {
        guard !chatHasActiveRun(session) else {
            showToast("Wait for this chat to stop before deleting it")
            return
        }
        guard !isBusy, !hasPendingPermission, !pendingSessionReset else {
            showToast("Finish the active run before deleting a chat")
            return
        }
        let wasActive = session.id == currentSessionID
        if wasActive {
            pendingSessionReset = true
            armSessionResetWatchdog()
        }
        Task {
            do {
                let response = try await backend.delete(
                    "/api/sessions/\(session.id)",
                    as: DeleteSessionResponse.self
                )
                if let replacement = response.replacementSessionInfo {
                    applySessionStarted(replacement, reason: "deleted_active")
                }
                sessions.removeAll { $0.id == session.id }
                // The conversation is gone; its pages have nothing to belong
                // to. (An Undo restores the transcript, not live tabs.)
                browser.closeTabs(ownedBy: session.id)
                pendingDeletedChat = DeletedChatUndo(
                    session: session,
                    trashBatch: response.trashBatch,
                    wasActive: response.deletedActive
                )
                showToast(
                    "Moved “\(session.displayTitle)” to recovery",
                    actionTitle: "Undo",
                    duration: 7
                )
            } catch {
                if wasActive {
                    pendingSessionReset = false
                    sessionResetWatchdog?.cancel()
                }
                showToast("Could not delete the chat: \(error.localizedDescription)")
            }
        }
    }

    func performToastAction() {
        guard toast?.actionTitle != nil, let deletion = pendingDeletedChat else { return }
        toastCenter.cancelPendingDismissal()
        toast = nil
        pendingDeletedChat = nil
        Task {
            do {
                let response = try await backend.post(
                    "/api/sessions/restore",
                    body: ["batch": deletion.trashBatch],
                    as: RestoreSessionsResponse.self
                )
                await refreshMetadata()
                guard response.restored > 0 else {
                    showToast("That chat could not be restored")
                    return
                }
                showToast("Chat restored")
                if deletion.wasActive,
                   let restoredID = response.sessionIDs.first,
                   let restored = sessions.first(where: { $0.id == restoredID })
                {
                    resume(restored)
                }
            } catch {
                showToast("Could not restore the chat: \(error.localizedDescription)")
            }
        }
    }

    func setShowArchived(_ value: Bool) {
        showArchivedSessions = value
        Task { await refreshMetadata() }
    }
}
