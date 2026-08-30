import Foundation

/// Forwarders kept while consumers still reach background services through
/// AppModel; each is deleted once its last caller observes
/// `model.backgroundServicesModel` directly.
extension AppModel {
    var backgroundServices: [BackgroundServiceRecord] {
        backgroundServicesModel.backgroundServices
    }

    func refreshBackgroundServices(recordingOutputs: Bool = false) {
        backgroundServicesModel.refreshBackgroundServices(recordingOutputs: recordingOutputs)
    }

    func stopAllBackgroundServices() {
        backgroundServicesModel.stopAllBackgroundServices()
    }

    func applyBackgroundServicesForTesting(_ services: [BackgroundServiceRecord]) {
        backgroundServicesModel.applyBackgroundServicesForTesting(services)
    }

    func stopBackgroundService(_ service: BackgroundServiceRecord) {
        backgroundServicesModel.stopBackgroundService(service)
    }
}
