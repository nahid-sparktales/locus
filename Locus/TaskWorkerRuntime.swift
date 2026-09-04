import Foundation

struct ChatAdmissionQueue {
    private(set) var sessionIDs: [String] = []

    mutating func enqueue(_ sessionID: String) {
        guard !sessionIDs.contains(sessionID) else { return }
        sessionIDs.append(sessionID)
    }

    mutating func remove(_ sessionID: String) {
        sessionIDs.removeAll { $0 == sessionID }
    }

    mutating func move(_ sessionID: String, action: String) {
        guard let index = sessionIDs.firstIndex(of: sessionID) else { return }
        switch action {
        case "move_top":
            sessionIDs.insert(sessionIDs.remove(at: index), at: 0)
        case "move_up" where index > 0:
            sessionIDs.swapAt(index, index - 1)
        case "move_down" where index + 1 < sessionIDs.count:
            sessionIDs.swapAt(index, index + 1)
        default:
            break
        }
    }

    func isFirst(_ sessionID: String) -> Bool {
        sessionIDs.first == sessionID
    }

    /// Preserve FIFO among chats that can start now while allowing an older
    /// writer blocked on a shared local workspace to stop holding unrelated
    /// work behind it.
    func isFirstEligible(
        _ sessionID: String,
        where isEligible: (String) -> Bool
    ) -> Bool {
        sessionIDs.first(where: isEligible) == sessionID
    }
}

/// One isolated local agent service for any chat. The main backend remains the
/// lightweight control service; runtimes own turn execution and survive
/// sidebar navigation until Locus quits.
@MainActor
final class ChatWorkerRuntime {
    let requestedSessionID: String
    let workspacePath: String
    var sessionID: String
    let process: BackendProcess
    let service: BackendService
    var isConnected = false
    var isAttaching = true
    /// A connected worker is not dispatchable while Locus is restoring
    /// settings through the backend's serialized state-mutation endpoint.
    /// Without this barrier, the next queued event can reach `start_turn`
    /// while `/api/permissions` still owns that lock and be rejected as busy.
    var isPreparingForDispatch = false
    var dispatchPreparationID: UUID?
    var sessionInfo: SessionInfo?
    var pendingForegroundEvent: [String: Any]?
    var executionState: TeamRunState = .queued
    var startedAt: Date?
    var lastError: String?
    var dispatchedMode: WorkMode?
    var dispatchedTeamRunID: String?
    var reservedRunID: String?
    var dispatchedInPlanMode = false
    var needsConnectorCapabilitySync = false
    var queuedMessages: [String] = []
    var streamingBlockID: UUID?
    var streamingText = ""
    var streamingReasoning = ""
    /// A question_ready captured while this chat runs in the background; armed
    /// into `pendingQuestion` when its turn completes.
    var capturedQuestion: UserQuestion?
    /// A completed background turn's unanswered question, promoted to the
    /// popup when the chat is brought to the foreground.
    var pendingQuestion: UserQuestion?
    /// A live structured question whose worker remains parked for an answer.
    var pendingBlockingQuestion: AgentQuestionRequest?
    private var awaitingTurnRequestIDs = Set<String>()
    private var acceptedTurnRequestIDs = Set<String>()

    var occupiesExecutionSlot: Bool {
        switch executionState {
        case .running, .dispatching, .waitingPermission, .waitingComputer,
             .waitingDispatchApproval, .reviewing:
            true
        default:
            false
        }
    }

    var acceptsNewTurns: Bool {
        Self.isDispatchReady(
            processRunning: process.isRunning,
            connected: isConnected,
            attaching: isAttaching,
            preparingConfiguration: isPreparingForDispatch
        )
    }

    static func isDispatchReady(
        processRunning: Bool,
        connected: Bool,
        attaching: Bool,
        preparingConfiguration: Bool
    ) -> Bool {
        processRunning && connected && !attaching && !preparingConfiguration
    }

    init(
        requestedSessionID: String,
        workspacePath: String,
        process: BackendProcess,
        endpoint: URL
    ) {
        self.requestedSessionID = requestedSessionID
        self.workspacePath = SessionSummary.canonicalWorkspacePath(workspacePath)
        sessionID = requestedSessionID
        self.process = process
        service = BackendService(baseURL: endpoint)
    }

    func stop() {
        service.disconnect()
        process.stop()
    }

    func prepareForTurnAcceptance(_ requestID: String) {
        awaitingTurnRequestIDs.insert(requestID)
        acceptedTurnRequestIDs.remove(requestID)
    }

    func recordTurnAcceptance(_ requestID: String) {
        guard !requestID.isEmpty, awaitingTurnRequestIDs.contains(requestID) else { return }
        acceptedTurnRequestIDs.insert(requestID)
    }

    func consumeTurnAcceptance(_ requestID: String) -> Bool {
        guard acceptedTurnRequestIDs.remove(requestID) != nil else { return false }
        awaitingTurnRequestIDs.remove(requestID)
        return true
    }

    func cancelTurnAcceptance(_ requestID: String) {
        awaitingTurnRequestIDs.remove(requestID)
        acceptedTurnRequestIDs.remove(requestID)
    }
}

/// Source compatibility for tests and extensions compiled against the first
/// team-only implementation.
typealias TaskWorkerRuntime = ChatWorkerRuntime
