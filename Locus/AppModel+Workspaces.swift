import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Workspace lifecycle from the UI: choose and create folders, switch the
/// active workspace, and remove workspace groups from the sidebar.
extension AppModel {
    func chooseWorkspace() {
        guard !chatNavigationDisabled else {
            showToast("Finish the active run before adding a workspace")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace"
        panel.message = "Pick a project folder, or use New Folder to start a new one."
        panel.prompt = "Use Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard workspaceAccess.rememberAndActivate(url) else {
            showToast("Locus could not retain access to that workspace")
            return
        }
        switchWorkspace(to: url.path)
    }

    /// Creates a folder and opens it as the workspace in one step.
    func createWorkspace() {
        guard !chatNavigationDisabled else {
            showToast("Finish the active run before creating a workspace")
            return
        }
        let panel = NSSavePanel()
        panel.title = "New Workspace"
        panel.message = "Name the folder Locus should create and open as the workspace."
        panel.prompt = "Create Workspace"
        panel.nameFieldLabel = "Workspace name:"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                showToast("A file with that name already exists")
                return
            }
            // The folder already exists — just open it.
            guard workspaceAccess.rememberAndActivate(url) else {
                showToast("Locus could not retain access to that workspace")
                return
            }
            switchWorkspace(to: url.path)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            showToast("Could not create the folder: \(error.localizedDescription)")
            return
        }
        guard workspaceAccess.rememberAndActivate(url) else {
            showToast("Locus could not retain access to that workspace")
            return
        }
        showToast("Created \(url.lastPathComponent)")
        switchWorkspace(to: url.path)
    }

    func switchWorkspace(to path: String) {
        guard (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil else {
            showToast("Finish the active run before switching workspaces")
            return
        }
        let path = SessionSummary.canonicalWorkspacePath(path)
        guard workspaceAccess.activateStored(path: path) else {
            showToast("Choose that workspace again to restore access")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            showToast("That workspace is no longer available")
            removeWorkspaceProfile(path)
            return
        }
        persistCurrentWorkspaceProfile()
        pendingWorkspacePath = path
        initialWorkspacePath = path
        expandedWorkspaceIDs.insert(path)
        persistExpandedWorkspaces()
        if persistenceEnabled, backendProcess.isRunning, WorkspaceAccess.isSandboxed {
            workspaceToOpenAfterReconnect = path
            backend.disconnect()
            sessionInfo = nil
            Task { [backendProcess] in
                await backendProcess.stopAndWait()
                await self.bootstrap()
            }
            showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        if let latest = sessions
            .filter({ $0.workspacePath == path })
            .max(by: { $0.mtime < $1.mtime })
        {
            resume(latest)
        } else {
            startNewChat(in: path, environment: nil)
        }
        showToast("Switching to \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func removeWorkspaceProfile(_ path: String) {
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        workspaceProfiles.removeAll {
            SessionSummary.canonicalWorkspacePath($0.path) == canonical
        }
        expandedWorkspaceIDs.remove(canonical)
        persistExpandedWorkspaces()
        persistWorkspaceProfiles()
    }

    /// Every unarchived chat that keeps a workspace group alive in the
    /// sidebar. Deliberately reads the full session list — the group's own
    /// snapshot is search- and archive-filtered, so it can hide chats that
    /// would resurrect the row after removal.
    func removableSidebarChats(for group: WorkspaceChatGroup) -> [SessionSummary] {
        guard let path = group.path else { return [] }
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        return sessions.filter { $0.workspacePath == canonical && !$0.isArchived }
    }

    func workspaceHasActiveRun(_ group: WorkspaceChatGroup) -> Bool {
        guard let path = group.path else { return false }
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        return sessions.contains { $0.workspacePath == canonical && chatHasActiveRun($0) }
    }

    /// Remove a workspace group from the sidebar. The profile disappears
    /// immediately; chats that would resurrect the group move to the archive,
    /// where the "All Workspaces" view can still restore them. Nothing on
    /// disk is touched.
    func removeWorkspaceFromSidebar(_ group: WorkspaceChatGroup) {
        guard let path = group.path else { return }
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        guard canonical != activeWorkspaceID else {
            showToast("Switch to another workspace before removing this one")
            return
        }
        guard !workspaceHasActiveRun(group) else {
            showToast("Wait for this workspace's runs to finish first")
            return
        }
        removeWorkspaceProfile(canonical)
        let toArchive = removableSidebarChats(for: group).filter { $0.id != currentSessionID }
        guard !toArchive.isEmpty else {
            showToast("Removed \(group.title) from the sidebar")
            return
        }
        Task {
            var failures = 0
            for chat in toArchive {
                do {
                    _ = try await backend.patch(
                        "/api/sessions/\(chat.id)",
                        body: ["archived": true],
                        as: SessionMetadataResponse.self
                    )
                } catch {
                    failures += 1
                }
            }
            await refreshMetadata()
            if failures == 0 {
                showToast(
                    "Removed \(group.title) — \(toArchive.count) "
                        + "\(toArchive.count == 1 ? "chat" : "chats") archived"
                )
            } else {
                showToast(
                    "Removed \(group.title), but \(failures) "
                        + "\(failures == 1 ? "chat" : "chats") could not be archived"
                )
            }
        }
    }
}
