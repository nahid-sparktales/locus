import Foundation

// Compatibility facade for non-reactive AppModel extension code. Reactive
// views observe LandingFlowModel directly.
extension AppModel {
    var taskHasChanges: Bool { landingFlow.taskHasChanges }
    func prepareReviewAndLand() { landingFlow.prepareReviewAndLand() }
}
