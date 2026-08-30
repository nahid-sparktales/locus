import Foundation

// Facade API — kept for InspectorView, which a concurrent branch owns
// right now; fold into `model.landingFlow` when that branch lands.
extension AppModel {
    var taskHasChanges: Bool { landingFlow.taskHasChanges }
    func prepareReviewAndLand() { landingFlow.prepareReviewAndLand() }
}
