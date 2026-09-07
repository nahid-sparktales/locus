import AppKit
import Foundation

extension AppModel {
    func activateWorkspaceBrowser() {
        guard sessionInfo != nil else { return }
        workspaceBrowser.onContentsChanged = { [weak self] root in
            guard let self, OutputsLibraryStore.canonical(self.workspacePath) == root else { return }
            self.workspaceFiles.invalidateIndex()
            if let path = self.workspaceFiles.previewedPath,
               !FileManager.default.fileExists(atPath: self.sessionFileURL(path).path) {
                self.workspaceFiles.closePreview()
            }
        }
        if isUITesting, ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_RESPONSE_OUTPUT"] == "1" {
            workspaceBrowser.activate(workspace: workspacePath, watch: false)
        } else if isUITesting {
            workspaceBrowser.seed(urls: workspaceFiles.files, workspace: workspacePath)
        } else {
            let changed = workspaceBrowser.workspace != OutputsLibraryStore.canonical(workspacePath)
            if changed { workspaceFiles.closePreview() }
            workspaceBrowser.activate(workspace: workspacePath)
        }
    }

    func openWorkspaceBrowserEntry(_ entry: WorkspaceBrowserEntry) {
        guard let url = MarkdownLinkPolicy.containedWorkspaceFileURL(entry.path, workspacePath: workspacePath) else {
            showToast("That file is no longer available in this workspace")
            return
        }
        workspaceBrowser.select(entry.path)
        if entry.isDirectory {
            if workspaceBrowser.isSearching { workspaceBrowser.revealDirectory(entry.path) }
            else { workspaceBrowser.toggle(entry.path) }
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("That file is no longer available in this workspace")
            return
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if entry.kind == .package || isDirectory {
            library.activate(workspace: workspacePath)
            library.isPresented = true
            library.showPreview(url: url, title: entry.name)
        } else {
            openSessionFile(entry.path)
        }
    }

    func addWorkspaceBrowserEntry(_ entry: WorkspaceBrowserEntry) {
        guard let url = MarkdownLinkPolicy.containedWorkspaceFileURL(entry.path, workspacePath: workspacePath),
              FileManager.default.fileExists(atPath: url.path) else {
            showToast("That file is no longer available in this workspace")
            return
        }
        switch entry.contextAction {
        case .context: addWorkspaceFileToContext(entry.path)
        case .attachment: loadChatAttachments(from: [url])
        case .unavailable: break
        }
    }
}
