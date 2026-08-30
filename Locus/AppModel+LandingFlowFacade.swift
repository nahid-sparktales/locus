import Foundation

/// Forwarders kept while consumers still reach the landing flow through
/// AppModel; each is deleted once its last caller observes
/// `model.landingFlow` directly.
extension AppModel {
    var landingPreflight: LandingPreflight? {
        get { landingFlow.landingPreflight }
        set { landingFlow.landingPreflight = newValue }
    }

    var landingPatch: String {
        get { landingFlow.landingPatch }
        set { landingFlow.landingPatch = newValue }
    }

    var reviewAndLandPresented: Bool {
        get { landingFlow.reviewAndLandPresented }
        set { landingFlow.reviewAndLandPresented = newValue }
    }

    var taskHasChanges: Bool {
        get { landingFlow.taskHasChanges }
        set { landingFlow.taskHasChanges = newValue }
    }

    var taskPatchBytes: Int {
        get { landingFlow.taskPatchBytes }
        set { landingFlow.taskPatchBytes = newValue }
    }

    var landingCheckRun: LandingCheckRun? { landingFlow.landingCheckRun }
    var activeLandingCheckRunID: String? { landingFlow.activeLandingCheckRunID }
    var isLandingOperationRunning: Bool {
        get { landingFlow.isLandingOperationRunning }
        set { landingFlow.isLandingOperationRunning = newValue }
    }

    func applyActiveTaskToWorkspace() { landingFlow.applyActiveTaskToWorkspace() }
    func prepareReviewAndLand() { landingFlow.prepareReviewAndLand() }
    func refreshLandingReview() async { await landingFlow.refreshLandingReview() }
    func runLandingChecks(commands: [String]) { landingFlow.runLandingChecks(commands: commands) }
    func stopLandingChecks() { landingFlow.stopLandingChecks() }

    func landActiveTask(
        destination: String, branch: String, commitMessage: String,
        overrideFailedChecks: Bool
    ) {
        landingFlow.landActiveTask(
            destination: destination, branch: branch, commitMessage: commitMessage,
            overrideFailedChecks: overrideFailedChecks
        )
    }
}
