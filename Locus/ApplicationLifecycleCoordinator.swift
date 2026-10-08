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
    private var hasCaptureWork: () -> Bool = { false }
    private var stopRunningWork: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var prepareOpenSettings: () -> Bool = { true }
    private var prepareNotesForShutdown: () -> Bool = { true }
    private var lockSensitiveServices: () -> Void = {}
    private weak var pendingTerminationApplication: NSApplication?
    private var updateContinuation: (@MainActor () -> Void)?
    private var updatePreparationID = UUID()

    init(stopRunningWork: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { $0() }) {
        self.stopRunningWork = stopRunningWork
    }

    func connect(model: AppModel) {
        hasRunningWork = { [weak model] in model?.hasRunningWorkForQuit == true }
        hasCaptureWork = { [weak model] in model?.outputsLibrary.hasCaptureWork == true }
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
        prepareNotesForShutdown = { [weak model] in
            do {
                try NotesStore.flushPendingChanges()
                return true
            } catch {
                model?.notebookPresented = true
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "A note could not be saved"
                alert.informativeText = "Your latest changes are still in memory. Retry saving in Notebook before quitting.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "Back to Notes")
                alert.runModal()
                return false
            }
        }
        lockSensitiveServices = { [weak model] in model?.lockSensitiveServicesForShutdown() }
    }

    /// Sparkle calls this before it asks AppKit to terminate the process. The
    /// install handler is deliberately retained and invoked once, after the
    /// same bounded cleanup used by an ordinary Quit.
    func prepareForUpdateRelaunch(continuation: @escaping @MainActor () -> Void) {
        guard state == .idle else { return }
        state = .preparingUpdate
        let preparationID = UUID()
        updatePreparationID = preparationID
        updateContinuation = continuation
        lockSensitiveServices()
        stopRunningWork { [weak self] in
            guard let self, self.state == .preparingUpdate,
                  self.updatePreparationID == preparationID else { return }
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

    /// Sparkle checks this both before postponing and when the retained install
    /// continuation re-enters its installer. The prepared continuation must be
    /// allowed through; rejecting it silently cancels Install and Restart.
    func shouldAllowUpdateRelaunch() -> Bool {
        switch state {
        case .idle: return prepareOpenSettings() && prepareNotesForShutdown()
        case .relaunching: return true
        case .preparingUpdate, .quitting: return false
        }
    }

    /// An installation that ends while this process remains alive must not
    /// retain a stale continuation or bypass preflight on its next attempt.
    func updateCycleDidFinish() {
        guard state == .preparingUpdate || state == .relaunching else { return }
        updatePreparationID = UUID()
        updateContinuation = nil
        state = .idle
        if let application = pendingTerminationApplication {
            pendingTerminationApplication = nil
            application.reply(toApplicationShouldTerminate: false)
        }
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

        guard prepareNotesForShutdown() else { return .terminateCancel }

        guard hasRunningWork() else {
            lockSensitiveServices()
            guard hasCaptureWork() else { return .terminateNow }
            state = .quitting
            // A just-finished task may still be saving its final snapshot.
            // Flush quietly; only running work requires the existing alert.
            stopRunningWork { [weak self, weak application] in
                guard self?.state == .quitting else { return }
                application?.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
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
