import Foundation

// Facade API — the routing state the send pipeline, split panes, chat
// workers, and team ops read on nearly every turn, plus the three
// collection members views observe broadly. Verbs and everything else
// live on `model.agentTeamsModel` directly.
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
