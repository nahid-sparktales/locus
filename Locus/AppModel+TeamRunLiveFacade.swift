import Foundation

// Facade API — kept for InspectorView (a concurrent branch owns it),
// AppModelTests, and the dispatcher seams. Shrinks to nothing once that
// branch lands and the tests are re-pointed in the follow-up.
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
