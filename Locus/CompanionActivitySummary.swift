import Foundation

/// Presentation of existing runtime truth. Availability never overwrites an
/// outstanding decision or unread result, and this type cannot control work.
struct CompanionActivitySummary: Equatable {
    struct Availability: Equatable {
        let runtimeConnected: Bool
        let modelConnected: Bool
        let detail: String
        var isAvailable: Bool { runtimeConnected && modelConnected }
    }

    enum Execution: Equatable {
        case idle, queued, working, needsApproval, failed, paused
        var title: String {
            switch self {
            case .idle: "Ready"
            case .queued: "Queued"
            case .working: "Working"
            case .needsApproval: "Needs approval"
            case .failed: "Needs recovery"
            case .paused: "Paused"
            }
        }
    }

    struct Run: Equatable {
        let id: String
        let state: TeamRunState
        let updatedAt: Double
        var sequence: Int = 0
        var unread = false
    }

    let availability: Availability
    let execution: Execution
    let approvalCount: Int
    let failureCount: Int
    let unreadCount: Int
    let workingCount: Int
    let queuedCount: Int
    let latestCompletion: ActivityCompletionEvent?

    var statusText: String {
        if execution == .idle && !availability.isAvailable { return availability.detail }
        return execution.title
    }

    var activityText: String {
        var parts: [String] = []
        if workingCount > 0 { parts.append("\(workingCount) working") }
        if queuedCount > 0 { parts.append("\(queuedCount) queued") }
        if approvalCount > 0 { parts.append("\(approvalCount) \(approvalCount == 1 ? "approval" : "approvals")") }
        if failureCount > 0 { parts.append("\(failureCount) \(failureCount == 1 ? "failure" : "failures")") }
        if unreadCount > 0 { parts.append("\(unreadCount) unread") }
        return parts.joined(separator: " · ")
    }

    var pose: CompanionCharacterPose {
        switch execution {
        case .idle: availability.isAvailable ? .idle : .unavailable
        case .queued: .queued
        case .working: availability.runtimeConnected ? .working : .unavailable
        case .needsApproval: .needsApproval
        case .failed: .failed
        case .paused: .paused
        }
    }

    static func make(availability: Availability, runs: [Run], approvalRunIDs: Set<String> = [],
                     standaloneApprovals: Int = 0, completionEvents: [ActivityCompletionEvent] = []) -> Self {
        var latest: [String: Run] = [:]
        for run in runs {
            if let existing = latest[run.id] {
                // A restored live cache cannot resurrect a terminal run. New
                // work has a new id; equal versions resolve deterministically.
                if existing.state.isTerminal && !run.state.isTerminal { continue }
                if run.state.isTerminal && !existing.state.isTerminal { latest[run.id] = run; continue }
                if (existing.sequence, existing.updatedAt, existing.state.rawValue)
                    >= (run.sequence, run.updatedAt, run.state.rawValue) { continue }
            }
            latest[run.id] = run
        }
        let all = Array(latest.values)
        let waiting: Set<TeamRunState> = [.waitingPermission, .waitingComputer, .waitingDispatchApproval]
        let approvalIDs = Set(all.filter { waiting.contains($0.state) }.map(\.id)).union(approvalRunIDs)
        let approvals = approvalIDs.count + standaloneApprovals
        let failures = all.filter { [.failed, .interrupted].contains($0.state) }.count
        let working = all.filter { [.running, .dispatching, .reviewing].contains($0.state) }.count
        let queued = all.filter { $0.state == .queued }.count
        let paused = all.contains { $0.state == .paused }
        let execution: Execution = approvals > 0 ? .needsApproval : working > 0 ? .working
            : queued > 0 ? .queued : failures > 0 ? .failed : paused ? .paused : .idle
        let completion = completionEvents.filter { latest[$0.runID] != nil }
            .max { ($0.occurredAt, $0.runID) < ($1.occurredAt, $1.runID) }
        return Self(availability: availability, execution: execution, approvalCount: approvals,
                    failureCount: failures, unreadCount: all.filter(\.unread).count,
                    workingCount: working, queuedCount: queued, latestCompletion: completion)
    }
}

extension AppModel {
    /// Global profile identity, current-project activity. This reads the normal
    /// session/run catalogs and existing live workers without any model calls.
    func companionActivitySummary(profileID: UUID) -> CompanionActivitySummary {
        let workspace = SessionSummary.canonicalWorkspacePath(workspacePath)
        let sessions = sessionCatalog.snapshot.sessionsByID
        func belongs(_ sessionID: String?, fallbackWorkspace: String? = nil) -> Bool {
            if let sessionID, let session = sessions[sessionID] { return session.belongsToWorkspace(workspace) }
            return fallbackWorkspace.map { SessionSummary.canonicalWorkspacePath($0) == workspace } ?? false
        }
        func owns(_ sessionID: String?) -> Bool {
            sessionID.map { savedAgentProfileID(for: $0) == profileID } ?? false
        }
        let available = companionAvailability(profileID: profileID)
        var samples: [CompanionActivitySummary.Run] = []
        let runSources = activity.visibleActivityRuns + runs.orchestrationRuns
            + Array(runs.runDetailsByID.values) + (runs.selectedOrchestrationRun.map { [$0] } ?? [])
        var ownedRunIDs = Set<String>()
        for run in runSources {
            guard belongs(run.sessionID, fallbackWorkspace: run.workspaceRoot),
                  owns(run.sessionID) || run.manifest?["agent_profile_id"]?.string.flatMap(UUID.init(uuidString:)) == profileID,
                  let state = TeamRunState(rawValue: run.state),
                  !activity.dismissedActivityRunIDs.contains(run.id) else { continue }
            ownedRunIDs.insert(run.id)
            samples.append(.init(id: run.id, state: state, updatedAt: run.updatedAt, sequence: run.lastSequence,
                                 unread: state.isTerminal && activity.activityIsUnseen(run)))
        }
        for (sessionID, live) in taskConversationStates {
            let fallback = taskWorkers[sessionID]?.workspacePath ?? (sessionID == currentSessionID ? workspacePath : nil)
            guard owns(sessionID), belongs(sessionID, fallbackWorkspace: fallback) else { continue }
            let id = live.runID ?? "session:\(sessionID)"
            guard !activity.dismissedActivityRunIDs.contains(id) else { continue }
            ownedRunIDs.insert(id)
            samples.append(.init(id: id, state: live.state, updatedAt: live.updatedAt.timeIntervalSince1970))
        }
        let decisions = activity.attentionItems.filter { item in
            item.group == .decisions && ((item.runID.map { ownedRunIDs.contains($0) } ?? false)
                || (owns(item.sessionID) && belongs(item.sessionID)))
        }
        let approvals = Set(decisions.compactMap(\.runID))
        return .make(availability: available, runs: samples, approvalRunIDs: approvals,
                     standaloneApprovals: decisions.filter { $0.runID == nil }.count,
                     completionEvents: Array(activity.liveCompletionEvents.values))
    }

    private func companionAvailability(profileID: UUID) -> CompanionActivitySummary.Availability {
        guard let profile = agentProfiles.first(where: { $0.id == profileID }) else {
            return .init(runtimeConnected: isAgentOnline, modelConnected: false, detail: "Agent unavailable")
        }
        let statuses = providerAccountsModel.accountStatus
        let route = SavedAgentOverviewSnapshot.route(profile: profile, accounts: providerAccounts,
            readyAccountIDs: Set(statuses.compactMap { $0.value.isHealthy ? $0.key : nil }),
            models: accountModels, statuses: statuses, localModels: providerAccountsModel.localModels.map(\.name))
        let issue: String?
        do { _ = try agentProfileProvider(profile); issue = route.issue }
        catch { issue = error.localizedDescription }
        let localHost = ["127.0.0.1", "localhost", "::1"].contains(backend.currentBaseURL.host ?? "")
        let location = localHost ? "on this Mac" : "on the connected runtime"
        let connected: Bool
        let connectionDetail: String
        switch profile.route {
        case .localOllama:
            connected = route.isVerified && activeAccount == nil && isModelOnline
            connectionDetail = activeAccount == nil ? (modelRuntimePhase.message ?? route.detail)
                : "Local model installed; connection not checked"
        case .providerAccount(let id):
            connected = route.isVerified && (activeAccount?.id != id || isModelOnline)
            connectionDetail = activeAccount?.id == id ? (modelRuntimePhase.message ?? route.detail) : route.detail
        }
        let detail = !isAgentOnline ? agentRuntimePhase.message ?? "Runtime unavailable"
            : issue ?? (connected ? "Ready \(location)" : connectionDetail)
        return .init(runtimeConnected: isAgentOnline, modelConnected: issue == nil && connected, detail: detail)
    }
}
