import Foundation

/// Forwarders kept while consumers still reach the AGENTS.md editor through
/// AppModel; each is deleted once its last caller observes
/// `model.agentInstructions` directly.
extension AppModel {
    var agentInstructionsExists: Bool {
        get { agentInstructions.agentInstructionsExists }
        set { agentInstructions.agentInstructionsExists = newValue }
    }

    var agentInstructionsDraft: String {
        get { agentInstructions.agentInstructionsDraft }
        set { agentInstructions.agentInstructionsDraft = newValue }
    }

    var savedAgentInstructions: String {
        get { agentInstructions.savedAgentInstructions }
        set { agentInstructions.savedAgentInstructions = newValue }
    }

    var agentInstructionsError: String? { agentInstructions.agentInstructionsError }
    var isLoadingAgentInstructions: Bool { agentInstructions.isLoadingAgentInstructions }
    var isSavingAgentInstructions: Bool { agentInstructions.isSavingAgentInstructions }
    var agentInstructionsHasUnsavedChanges: Bool { agentInstructions.agentInstructionsHasUnsavedChanges }
    var agentInstructionsURL: URL { agentInstructions.agentInstructionsURL }

    func refreshAgentInstructions(discardingChanges: Bool = false) {
        agentInstructions.refreshAgentInstructions(discardingChanges: discardingChanges)
    }

    func createAgentInstructions() {
        agentInstructions.createAgentInstructions()
    }

    func saveAgentInstructions() {
        agentInstructions.saveAgentInstructions()
    }

    func revertAgentInstructions() {
        agentInstructions.revertAgentInstructions()
    }

    func revealAgentInstructionsInFinder() {
        agentInstructions.revealAgentInstructionsInFinder()
    }
}
