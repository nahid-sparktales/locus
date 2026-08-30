import Foundation

struct AppLifecycleRunSnapshot: Codable, Equatable {
    let sessionID: String
    let runID: String
    let state: TeamRunState
    let updatedAt: Date
}

struct AppLifecycleRecovery: Equatable {
    let snapshot: AppLifecycleRunSnapshot?

    var message: String {
        guard let snapshot else {
            return "Locus did not close normally. Your last session was restored."
        }
        switch snapshot.state {
        case .completed:
            return "Locus was force quit after the team run completed. Its results were restored."
        case .failed, .cancelled, .discarded:
            return "Locus did not close normally. The last team run finished as \(snapshot.state.title.lowercased())."
        case .interrupted:
            return "Locus closed unexpectedly. The interrupted team run is ready to resume."
        case .queued, .dispatching, .running, .waitingPermission, .waitingComputer,
             .waitingDispatchApproval, .reviewing, .paused:
            return "Locus closed unexpectedly. The last team run can be inspected and resumed."
        }
    }
}

/// A deliberately tiny crash journal. The durable session/run database remains
/// authoritative; these defaults only tell the next launch what to reopen and
/// whether the previous process reached its ordinary termination hook.
final class AppLifecycleJournal {
    private let defaults: UserDefaults
    private let cleanKey: String
    private let snapshotKey: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "Locus.lifecycle") {
        self.defaults = defaults
        cleanKey = "\(keyPrefix).clean"
        snapshotKey = "\(keyPrefix).latestRun"
    }

    @discardableResult
    func beginLaunch() -> AppLifecycleRecovery? {
        let hadPreviousLaunch = defaults.object(forKey: cleanKey) != nil
        let previousLaunchWasClean = defaults.bool(forKey: cleanKey)
        let snapshot = defaults.data(forKey: snapshotKey)
            .flatMap { try? JSONDecoder().decode(AppLifecycleRunSnapshot.self, from: $0) }
        // Set this before any services are started. Force Quit cannot run a
        // callback, so leaving this false is the abnormal-exit signal.
        defaults.set(false, forKey: cleanKey)
        guard hadPreviousLaunch, !previousLaunchWasClean else { return nil }
        return AppLifecycleRecovery(snapshot: snapshot)
    }

    func record(sessionID: String, runID: String, state: TeamRunState, at date: Date = Date()) {
        guard !sessionID.isEmpty, !runID.isEmpty else { return }
        let snapshot = AppLifecycleRunSnapshot(
            sessionID: sessionID,
            runID: runID,
            state: state,
            updatedAt: date
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    func markCleanExit() {
        defaults.set(true, forKey: cleanKey)
    }
}
