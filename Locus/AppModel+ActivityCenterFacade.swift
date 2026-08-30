import Foundation

// Facade API — permanent forwarder; broadly load-bearing across views and
// the companion surface. Everything else on ActivityCenterModel is reached
// through `model.activity` directly.
extension AppModel {
    var visibleActivityRuns: [OrchestrationRun] { activity.visibleActivityRuns }
}
