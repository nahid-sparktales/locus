import AppKit
import Combine

/// Owns every application-level shutdown transition. Window dismissal remains
/// a presentation concern, while normal Quit and updater-driven relaunch share
/// one bounded cleanup path so AppKit is never answered twice.
@MainActor
final class ApplicationLifecycleCoordinator: ObservableObject, AppUpdateRelaunchHandling {
    enum State: Equatable {
        case idle
        case quitting
        case preparingUpdate
        case relaunching
    }

    @Published private(set) var state: State = .idle

    private var hasRunningWork: () -> Bool = { false }
    private var terminalHasForegroundJob: () -> Bool = { false }
    private var stopRunningWork: (@escaping @MainActor () -> Void) -> Void = { completion in
        completion()
    }
    private var prepareOpenSettings: () -> Bool = { true }
    private var lockSensitiveServices: () -> Void = {}
    private weak var pendingTerminationApplication: NSApplication?
    private var updateContinuation: (@MainActor () -> Void)?

    func connect(model: AppModel) {
        hasRunningWork = { [weak model] in model?.hasRunningWorkForQuit == true }
        terminalHasForegroundJob = { [weak model] in
            model?.terminal.hasForegroundJob == true
        }
        stopRunningWork = { [weak model] completion in
            guard let model else {
                completion()
                return
            }
            model.stopRunningWorkForQuit(completion: completion)
        }
        prepareOpenSettings = { [weak model] in
            model?.prepareOpenSettingsForUpdate() ?? true
        }
        lockSensitiveServices = { [weak model] in model?.lockSensitiveServicesForShutdown() }
    }

    /// Sparkle calls this before it asks AppKit to terminate the process. The
    /// install handler is deliberately retained and invoked once, after the
    /// same bounded cleanup used by an ordinary Quit.
    func prepareForUpdateRelaunch(continuation: @escaping @MainActor () -> Void) {
        guard state == .idle else { return }
        state = .preparingUpdate
        updateContinuation = continuation
        lockSensitiveServices()
        stopRunningWork { [weak self] in
            guard let self, self.state == .preparingUpdate else { return }
            self.state = .relaunching
            if let application = self.pendingTerminationApplication {
                self.pendingTerminationApplication = nil
                application.reply(toApplicationShouldTerminate: true)
            }
            let continuation = self.updateContinuation
            self.updateContinuation = nil
            continuation?()
        }
    }

    /// Sparkle checks this before entering its postponed relaunch path. This
    /// is the only point where returning false cleanly aborts the installation,
    /// so staged Settings validation belongs here rather than in the retained
    /// continuation.
    func shouldAllowUpdateRelaunch() -> Bool {
        guard state == .idle else { return false }
        return prepareOpenSettings()
    }

    func updaterWillRelaunch() {
        guard state == .preparingUpdate || state == .relaunching else { return }
        state = .relaunching
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .preparingUpdate:
            pendingTerminationApplication = application
            return .terminateLater
        case .relaunching:
            return .terminateNow
        case .quitting:
            return .terminateLater
        case .idle:
            break
        }

        guard hasRunningWork() else {
            lockSensitiveServices()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Stop running processes and quit Locus?"
        alert.informativeText = terminalHasForegroundJob()
            ? "The terminal has a foreground job. It will be stopped; resumable agent tasks and private checkouts remain available."
            : "The active team and its private checkout will remain available to resume."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        state = .quitting
        lockSensitiveServices()
        stopRunningWork { [weak self, weak application] in
            guard let self, self.state == .quitting else { return }
            application?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
