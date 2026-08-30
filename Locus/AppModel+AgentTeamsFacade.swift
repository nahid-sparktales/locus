import Foundation

/// Forwarders kept while consumers still reach team configuration through
/// AppModel; each is deleted once its last caller observes
/// `model.agentTeamsModel` directly.
extension AppModel {
    var primaryAgentBehavior: AgentBehavior { agentTeamsModel.primaryAgentBehavior }
    var teamRoutingConsentAccountIDs: Set<UUID> { agentTeamsModel.teamRoutingConsentAccountIDs }
    var selectedAgentTeam: AgentTeam? { agentTeamsModel.selectedAgentTeam }
    var teamModeEnabled: Bool { agentTeamsModel.teamModeEnabled }

    var agentProfiles: [AgentProfile] {
        get { agentTeamsModel.agentProfiles }
        set { agentTeamsModel.agentProfiles = newValue }
    }

    var agentTeams: [AgentTeam] {
        get { agentTeamsModel.agentTeams }
        set { agentTeamsModel.agentTeams = newValue }
    }

    var globalAgentConcurrency: Int {
        get { agentTeamsModel.globalAgentConcurrency }
        set { agentTeamsModel.globalAgentConcurrency = newValue }
    }

    var selectedAgentTeamID: UUID? {
        get { agentTeamsModel.selectedAgentTeamID }
        set { agentTeamsModel.selectedAgentTeamID = newValue }
    }

    var soloSwarmEnabled: Bool {
        get { agentTeamsModel.soloSwarmEnabled }
        set { agentTeamsModel.soloSwarmEnabled = newValue }
    }

    func suggestedQuickTeamName() -> String { agentTeamsModel.suggestedQuickTeamName() }

    func missingQuickTeamRoutingAccounts(for draft: QuickTeamDraft) -> [ProviderAccount] {
        agentTeamsModel.missingQuickTeamRoutingAccounts(for: draft)
    }

    @discardableResult
    func createAndSelectQuickTeam(
        _ draft: QuickTeamDraft
    ) -> Result<AgentTeam, QuickTeamCreationError> {
        agentTeamsModel.createAndSelectQuickTeam(draft)
    }

    func selectAgentTeam(_ id: UUID?) { agentTeamsModel.selectAgentTeam(id) }
    func selectSoloRoute() { agentTeamsModel.selectSoloRoute() }

    func savePrimaryAgentBehavior(_ behavior: AgentBehavior) {
        agentTeamsModel.savePrimaryAgentBehavior(behavior)
    }

    func saveAgentProfile(_ profile: AgentProfile) { agentTeamsModel.saveAgentProfile(profile) }
    func removeAgentProfile(_ profile: AgentProfile) { agentTeamsModel.removeAgentProfile(profile) }
    func saveAgentTeam(_ team: AgentTeam) { agentTeamsModel.saveAgentTeam(team) }
    func removeAgentTeam(_ team: AgentTeam) { agentTeamsModel.removeAgentTeam(team) }

    func grantAutomaticRoutingConsent(for accountID: UUID) {
        agentTeamsModel.grantAutomaticRoutingConsent(for: accountID)
    }

    func revokeAutomaticRoutingConsent(for accountID: UUID) {
        agentTeamsModel.revokeAutomaticRoutingConsent(for: accountID)
    }
}
