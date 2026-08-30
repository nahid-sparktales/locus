import Foundation

/// Forwarders kept while consumers still reach the Activity Center through
/// AppModel; each is deleted once its last caller observes `model.activity`
/// directly.
extension AppModel {
    var activityCenterPresented: Bool {
        get { activity.activityCenterPresented }
        set { activity.activityCenterPresented = newValue }
    }

    var activityCenterSection: ActivityCenterSection {
        get { activity.activityCenterSection }
        set { activity.activityCenterSection = newValue }
    }

    var activityRuns: [OrchestrationRun] {
        get { activity.activityRuns }
        set { activity.activityRuns = newValue }
    }

    var activitySeenUpdates: [String: Double] { activity.activitySeenUpdates }
    var dismissedActivityRunIDs: Set<String> { activity.dismissedActivityRunIDs }
    var activityNeedsAttentionCount: Int { activity.activityNeedsAttentionCount }
    var visibleActivityRuns: [OrchestrationRun] { activity.visibleActivityRuns }

    func refreshActivityRuns(announceFailure: Bool = true) async {
        await activity.refreshActivityRuns(announceFailure: announceFailure)
    }

    func openActivityCenter() { activity.openActivityCenter() }
    func toggleActivityCenter() { activity.toggleActivityCenter() }
    func activityIsUnseen(_ run: OrchestrationRun) -> Bool { activity.activityIsUnseen(run) }
    func markActivitySeen(_ run: OrchestrationRun) { activity.markActivitySeen(run) }
    func markAllActivitySeen() { activity.markAllActivitySeen() }
    func dismissActivityRun(_ run: OrchestrationRun) { activity.dismissActivityRun(run) }
    func clearFinishedActivityRuns() { activity.clearFinishedActivityRuns() }
}
