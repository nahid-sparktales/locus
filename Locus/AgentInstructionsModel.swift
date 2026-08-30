import AppKit
import Foundation

/// Owns the workspace-root AGENTS.md editor: load, save, create, and revert
/// with dirty-state protection. AppModel wires it via configure(...) and
/// bridges its publication; it never retains AppModel.
@MainActor
final class AgentInstructionsModel: ObservableObject {
    @Published var agentInstructionsExists = false
    @Published var agentInstructionsDraft = ""
    @Published var savedAgentInstructions = ""
    @Published private(set) var agentInstructionsError: String?
    @Published private(set) var isLoadingAgentInstructions = false
    @Published private(set) var isSavingAgentInstructions = false

    private var agentInstructionsTask: Task<Void, Never>?

    private var backend: BackendService?
    private var isUITesting = false
    private var workspacePathProvider: () -> String = { "" }
    private var runIsActive: () -> Bool = { false }
    private var toastHandler: (String) -> Void = { _ in }
    private var workspaceFilesChanged: () -> Void = {}

    func configure(
        backend: BackendService,
        isUITesting: Bool,
        workspacePathProvider: @escaping () -> String,
        runIsActive: @escaping () -> Bool,
        toastHandler: @escaping (String) -> Void,
        workspaceFilesChanged: @escaping () -> Void
    ) {
        self.backend = backend
        self.isUITesting = isUITesting
        self.workspacePathProvider = workspacePathProvider
        self.runIsActive = runIsActive
        self.toastHandler = toastHandler
        self.workspaceFilesChanged = workspaceFilesChanged
    }

    func cancelAll() {
        agentInstructionsTask?.cancel()
        agentInstructionsTask = nil
    }

    var agentInstructionsHasUnsavedChanges: Bool {
        agentInstructionsDraft != savedAgentInstructions
    }

    var agentInstructionsURL: URL {
        AgentInstructionsFile.url(for: workspacePathProvider())
    }

    /// Reads the workspace-root AGENTS.md without ever wandering outside the
    /// selected folder. A dirty editor is protected unless the user explicitly
    /// chooses Revert.
    func refreshAgentInstructions(discardingChanges: Bool = false) {
        guard !isUITesting else { return }
        if agentInstructionsHasUnsavedChanges, !discardingChanges {
            toastHandler("Save or revert the AGENTS.md edits first")
            return
        }

        let root = workspacePathProvider()
        agentInstructionsTask?.cancel()
        isLoadingAgentInstructions = true
        agentInstructionsError = nil
        agentInstructionsTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                AgentInstructionsFile.load(from: root)
            }.value
            guard let self, self.workspacePathProvider() == root, !Task.isCancelled else { return }
            self.isLoadingAgentInstructions = false
            self.agentInstructionsExists = snapshot.exists
            self.agentInstructionsError = snapshot.error
            guard snapshot.error == nil else { return }
            self.savedAgentInstructions = snapshot.content
            self.agentInstructionsDraft = snapshot.content
        }
    }

    func createAgentInstructions() {
        guard !agentInstructionsExists else {
            refreshAgentInstructions()
            return
        }
        agentInstructionsDraft = "# Workspace instructions\n\n"
        saveAgentInstructions()
    }

    func saveAgentInstructions() {
        guard !runIsActive() else {
            toastHandler("Wait for the current run to finish before saving AGENTS.md")
            return
        }
        guard agentInstructionsHasUnsavedChanges || !agentInstructionsExists else { return }

        let root = workspacePathProvider()
        let contents = agentInstructionsDraft
        isSavingAgentInstructions = true
        agentInstructionsError = nil
        agentInstructionsTask?.cancel()
        agentInstructionsTask = Task { [weak self] in
            let errorMessage = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try AgentInstructionsFile.save(contents, in: root)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self, self.workspacePathProvider() == root, !Task.isCancelled else { return }
            self.isSavingAgentInstructions = false
            if let errorMessage {
                self.agentInstructionsError = errorMessage
                self.toastHandler("Could not save AGENTS.md")
                return
            }

            self.agentInstructionsExists = true
            self.savedAgentInstructions = contents
            self.workspaceFilesChanged()

            do {
                guard let backend = self.backend else { return }
                let _: ProjectContextReloadResponse = try await backend.post(
                    "/api/context/reload",
                    body: [:],
                    as: ProjectContextReloadResponse.self
                )
                self.toastHandler("Saved AGENTS.md — instructions reloaded")
            } catch {
                // The file is already safely on disk. The backend also reloads
                // project instructions at the next Work turn, so a reconnect or
                // narrow race with a finishing turn never loses the edit.
                self.toastHandler("Saved AGENTS.md — applies on the next Work turn")
            }
        }
    }

    func revertAgentInstructions() {
        if agentInstructionsExists {
            refreshAgentInstructions(discardingChanges: true)
        } else {
            agentInstructionsDraft = ""
            savedAgentInstructions = ""
            agentInstructionsError = nil
        }
    }

    func revealAgentInstructionsInFinder() {
        guard agentInstructionsExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([agentInstructionsURL])
    }
}
