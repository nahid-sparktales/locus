import Foundation

/// One isolated local agent service for a team-backed chat. The main backend
/// remains the lightweight control service; these runtimes own turn execution
/// and survive sidebar navigation until Locus quits.
@MainActor
final class TaskWorkerRuntime {
    let requestedSessionID: String
    var sessionID: String
    let process: BackendProcess
    let service: BackendService
    var isConnected = false
    var isAttaching = true
    var sessionInfo: SessionInfo?
    var pendingForegroundEvent: [String: Any]?

    init(requestedSessionID: String, process: BackendProcess, endpoint: URL) {
        self.requestedSessionID = requestedSessionID
        sessionID = requestedSessionID
        self.process = process
        service = BackendService(baseURL: endpoint)
    }

    func stop() {
        service.disconnect()
        process.stop()
    }
}
