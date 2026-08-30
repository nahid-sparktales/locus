import Foundation

/// Owns the transient toast and its auto-dismiss. The undo payload for chat
/// deletion stays with session maintenance on AppModel; it is cleared through
/// onToastReplaced whenever a plain toast displaces an actionable one.
@MainActor
final class ToastCenter: ObservableObject {
    @Published var toast: AppToast?

    private var toastTask: Task<Void, Never>?

    var onToastReplaced: () -> Void = {}

    func showToast(
        _ message: String,
        actionTitle: String? = nil,
        duration: Double = 2.4
    ) {
        toastTask?.cancel()
        if actionTitle == nil { onToastReplaced() }
        toast = AppToast(
            message: message,
            actionTitle: actionTitle
        )
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.onToastReplaced()
        }
    }

    func cancelPendingDismissal() {
        toastTask?.cancel()
    }
}
