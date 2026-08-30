import Foundation

/// Forwarders kept while consumers still reach the live team run's
/// presentation through AppModel; each is deleted once its last caller
/// observes `model.teamRunLive` directly.
extension AppModel {
    var dispatcherActivity: AgentActivity? {
        get { teamRunLive.dispatcherActivity }
        set { teamRunLive.dispatcherActivity = newValue }
    }

    var dispatcherValidationReason: String? {
        get { teamRunLive.dispatcherValidationReason }
        set { teamRunLive.dispatcherValidationReason = newValue }
    }

    var pendingDispatchPlan: DispatchPlan? {
        get { teamRunLive.pendingDispatchPlan }
        set { teamRunLive.pendingDispatchPlan = newValue }
    }

    var agentActivities: [AgentActivity] { teamRunLive.agentActivities }
    var teamModelCalls: Int { teamRunLive.teamModelCalls }
    var teamMeteredTokens: Int { teamRunLive.teamMeteredTokens }
    var shouldShowTeamDispatchProgress: Bool { teamRunLive.shouldShowTeamDispatchProgress }
    var shouldShowTeamDispatchApproval: Bool { teamRunLive.shouldShowTeamDispatchApproval }
    var activeOrchestrationTeam: AgentTeam? { teamRunLive.activeOrchestrationTeam }
}
