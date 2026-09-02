import Foundation

// Compatibility facade for non-reactive orchestration and the companion
// surface. Reactive views observe ActivityCenterModel directly.
extension AppModel {
    var visibleActivityRuns: [OrchestrationRun] { activity.visibleActivityRuns }
}
