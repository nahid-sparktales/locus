import Foundation

/// showToast stays permanently on the facade: it is AppModel's most-called
/// member, and every feature model receives it as a closure.
extension AppModel {
    var toast: AppToast? {
        get { toastCenter.toast }
        set { toastCenter.toast = newValue }
    }

    func showToast(
        _ message: String,
        actionTitle: String? = nil,
        duration: Double = 2.4
    ) {
        toastCenter.showToast(message, actionTitle: actionTitle, duration: duration)
    }
}
