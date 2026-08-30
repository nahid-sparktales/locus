import Foundation

/// Forwarders kept while consumers still reach workspace knowledge through
/// AppModel; each is deleted once its last caller observes `model.knowledge`
/// directly.
extension AppModel {
    var knowledgeStatus: WorkspaceKnowledgeStatus? { knowledge.knowledgeStatus }
    var workspaceMemories: [WorkspaceMemory] { knowledge.workspaceMemories }
    var memoryCandidates: [WorkspaceMemory] { knowledge.memoryCandidates }
    var memoryVaultStatus: MemoryVaultStatus? { knowledge.memoryVaultStatus }
    var memoryDiagnosticReport: MemoryDiagnosticReport? { knowledge.memoryDiagnosticReport }
    var contextSnapshots: [ContextSnapshot] { knowledge.contextSnapshots }
    var skillObservations: [SkillObservation] { knowledge.skillObservations }

    func refreshWorkspaceKnowledge(agentID: String = "primary") async {
        await knowledge.refreshWorkspaceKnowledge(agentID: agentID)
    }

    func setContextSnapshotPinned(_ snapshot: ContextSnapshot, pinned: Bool) {
        knowledge.setContextSnapshotPinned(snapshot, pinned: pinned)
    }

    func deleteContextSnapshot(_ snapshot: ContextSnapshot) {
        knowledge.deleteContextSnapshot(snapshot)
    }

    func clearContextSnapshots() {
        knowledge.clearContextSnapshots()
    }

    func setSkillObservationStatus(_ observation: SkillObservation, status: String) {
        knowledge.setSkillObservationStatus(observation, status: status)
    }

    func deleteSkillObservation(_ observation: SkillObservation) {
        knowledge.deleteSkillObservation(observation)
    }

    func exportSkillObservations() {
        knowledge.exportSkillObservations()
    }

    func configureWorkspaceKnowledge(
        enabled: Bool,
        embeddingModel: String,
        exclusions: [String] = []
    ) {
        knowledge.configureWorkspaceKnowledge(
            enabled: enabled,
            embeddingModel: embeddingModel,
            exclusions: exclusions
        )
    }

    func rebuildWorkspaceKnowledge() {
        knowledge.rebuildWorkspaceKnowledge()
    }

    func rememberWorkspaceFact(
        title: String,
        content: String,
        tags: [String],
        scope: AgentMemoryScope = .workspace,
        kind: MemoryKind = .fact,
        confidence: Double = 1,
        validUntil: Double? = nil,
        agentID: String = "primary"
    ) {
        knowledge.rememberWorkspaceFact(
            title: title,
            content: content,
            tags: tags,
            scope: scope,
            kind: kind,
            confidence: confidence,
            validUntil: validUntil,
            agentID: agentID
        )
    }

    func deleteWorkspaceMemory(_ memory: WorkspaceMemory, agentID: String = "primary") {
        knowledge.deleteWorkspaceMemory(memory, agentID: agentID)
    }

    func updateWorkspaceMemory(_ memory: WorkspaceMemory, agentID: String = "primary") {
        knowledge.updateWorkspaceMemory(memory, agentID: agentID)
    }

    func approveMemoryCandidate(
        _ memory: WorkspaceMemory,
        agentID: String = "primary",
        replacingConflicts: Bool = false
    ) {
        knowledge.approveMemoryCandidate(
            memory,
            agentID: agentID,
            replacingConflicts: replacingConflicts
        )
    }

    func reviewMemoryHealth(agentID: String = "primary") {
        knowledge.reviewMemoryHealth(agentID: agentID)
    }

    func reprocessCurrentChatMemory(agentID: String = "primary") {
        knowledge.reprocessCurrentChatMemory(agentID: agentID)
    }

    func exportMemory(agentID: String = "primary") {
        knowledge.exportMemory(agentID: agentID)
    }

    func importMemory(agentID: String = "primary") {
        knowledge.importMemory(agentID: agentID)
    }

    func deleteAllWorkspaceKnowledge(agentID: String = "primary") {
        knowledge.deleteAllWorkspaceKnowledge(agentID: agentID)
    }

    func deleteAllMemory(agentID: String = "primary") {
        knowledge.deleteAllMemory(agentID: agentID)
    }
}
