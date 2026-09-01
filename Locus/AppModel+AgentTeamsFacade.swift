import Foundation

// Compatibility facade for routing state used by the send pipeline, split
// panes, chat workers, and team orchestration. Reactive views observe
// AgentTeamsModel directly.
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
}
