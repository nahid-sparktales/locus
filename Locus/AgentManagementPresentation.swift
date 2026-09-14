import Foundation

/// A single timeline preserves typed provenance even if a schedule and an
/// incoming event share the same storage ID. Duration belongs to executions,
/// not receipt timestamps, and is deliberately left to the run inspector.
struct AgentActivityRecord: Identifiable {
    let id: String
    let agent: AgentInspectorAgent
    let agentName: String
    let title: String
    let sourceTitle: String
    let timestamp: Double
    let state: String
    let error: String?
    let context: AgentInspectorContext
    let delivery: EventDelivery?

    var needsAttention: Bool {
        ["failed", "interrupted", "waiting_permission", "waiting_computer",
         "waiting_dispatch_approval", "waiting_approval"].contains(state)
            || (state != "skipped" && error?.isEmpty == false)
    }
    var isInProgress: Bool {
        ["pending", "queued", "claiming", "dispatching", "planning", "running", "advancing", "awaiting_run"].contains(state)
    }
    var canRetry: Bool {
        delivery.map { ["failed", "interrupted", "cancelled"].contains($0.state) } ?? false
    }
    var statusTitle: String {
        switch state {
        case "running", "advancing": "Running"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        default: AgentInspectorCopy.state(state)
        }
    }
    var symbol: String {
        if needsAttention { return "exclamationmark.circle.fill" }
        if isInProgress { return "circle.dotted" }
        switch state {
        case "completed": return "checkmark.circle.fill"
        case "skipped": return "forward.end.circle"
        case "cancelled", "discarded": return "xmark.circle"
        case "paused": return "pause.circle"
        default: return "questionmark.circle"
        }
    }

    static func merged(deliveries: [EventDelivery], occurrences: [ScheduleOccurrence], definitions: [AgentDefinition]) -> [Self] {
        let events = deliveries.map { delivery in
            let agent = AgentInspectorAgent(kind: .event, agentID: delivery.triggerID)
            let name = definitions.first { !$0.isSchedule && $0.id == delivery.triggerID }?.name ?? "Removed Agent"
            let state = AgentInspectorCopy.effectiveActivityState(
                deliveryState: delivery.state, runState: delivery.runState
            )
            return Self(id: "event:\(delivery.id)", agent: agent, agentName: name,
                title: delivery.event.subject.isEmpty ? delivery.event.eventType : delivery.event.subject,
                sourceTitle: delivery.source.title, timestamp: delivery.receivedAt, state: state,
                error: delivery.error, context: .event(agent, deliveryID: delivery.id), delivery: delivery)
        }
        let runs = occurrences.map { occurrence in
            let agent = AgentInspectorAgent(kind: .schedule, agentID: occurrence.scheduleID)
            return Self(id: "schedule:\(occurrence.id)", agent: agent,
                agentName: definitions.first { $0.isSchedule && $0.id == occurrence.scheduleID }?.name ?? occurrence.scheduleName,
                title: occurrence.trigger == "manual" ? "Started manually" : "Scheduled run",
                sourceTitle: "Schedule", timestamp: occurrence.scheduledFor, state: occurrence.state,
                error: occurrence.error, context: .occurrence(agent, occurrenceID: occurrence.id), delivery: nil)
        }
        return (events + runs).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
    }

    /// The profile selected in Manage Agent scopes the whole timeline before
    /// its status or automation filters apply. Archived chats retain ownership
    /// of history even after an automation is removed.
    static func scoped(
        _ records: [Self], to profileID: UUID?,
        sessions: [SessionSummary], definitions: [AgentDefinition]
    ) -> [Self] {
        guard let profileID else { return records }
        let ownedAgents = Set(sessions.filter { $0.savedAgentProfileID == profileID }
            .compactMap { $0.agentReference(in: definitions) })
        return records.filter { ownedAgents.contains($0.agent) }
    }
}

enum AgentActivityFilter: String, CaseIterable, Identifiable {
    case all, attention, inProgress, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All statuses"
        case .attention: "Needs attention"
        case .inProgress: "In progress"
        case .completed: "Completed"
        }
    }
    func includes(_ record: AgentActivityRecord) -> Bool {
        switch self {
        case .all: true
        case .attention: record.needsAttention
        case .inProgress: record.isInProgress
        case .completed: record.state == "completed" && !record.needsAttention
        }
    }
}

/// Read-only projection for one saved profile. Ownership comes from durable
/// session metadata, including archived sessions, never names or model routes.
struct SavedAgentOverviewSnapshot {
    enum Status: Equatable { case ready, working, needsAttention, paused, unverified }
    enum Action: Hashable {
        case editAgent, manageAccount(UUID?), connections
        case automation(AgentInspectorAgent), activity(AgentInspectorContext), chat(String)
        case attention(ActivityCenterModel.Focus)
    }
    struct Route {
        let accountID: UUID?
        let title: String
        let model: String
        let detail: String
        let issue: String?
        let isVerified: Bool
    }
    struct Issue: Identifiable {
        let id: String
        let title: String
        let detail: String
        let action: Action?
    }
    struct Connection: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isHealthy: Bool
        let action: Action
        var needsAttention: Bool { !isHealthy }
    }
    struct Automation: Identifiable {
        let reference: AgentInspectorAgent
        let definition: AgentDefinition
        let enabled: Bool
        let statusTitle: String
        let detail: String
        let nextRunAt: Date?
        let latestActivity: AgentActivityRecord?
        let needsAttention: Bool
        let isBusy: Bool
        let action: Action
        var id: String { reference.id }
    }
    struct LatestResult: Identifiable {
        let id: String
        let title: String
        let state: String
        let statusTitle: String
        let summary: String
        let timestamp: Date
        let isInProgress: Bool
        let needsAttention: Bool
        let action: Action?
        let sessionID: String?
        let runID: String?
    }
    /// The same read-only session response used by chat restoration, retaining
    /// its durable profile binding before exposing any assistant content.
    struct ResultTranscript: Decodable {
        let id: String
        let profileID: UUID?
        let messages: [HistoryMessage]

        enum CodingKeys: String, CodingKey {
            case id, messages
            case profileID = "agent_profile_id"
        }

        func lastAnswer(profileID expectedProfileID: UUID, sessionID: String, runID: String?) -> HistoryMessage? {
            guard id == sessionID, profileID == expectedProfileID else { return nil }
            return messages.last {
                $0.role == "assistant" && $0.phase != .commentary && $0.content.nilIfEmpty != nil
                    && (runID == nil || $0.runID == runID)
            }
        }
    }

    let profileID: UUID
    let status: Status
    let statusTitle: String
    let detail: String
    let isBusy: Bool
    let needsAttention: Bool
    let route: Route
    let issues: [Issue]
    let connections: [Connection]
    let automations: [Automation]
    let latestResult: LatestResult?
    /// At most this one owned conversation needs a read-only output fetch.
    let resultSessionID: String?
    /// Workspace filtering affects this list only. Readiness and automation
    /// ownership continue to describe the whole saved agent.
    let chats: [SessionSummary]

    static func resolve(
        profile: AgentProfile,
        sessions: [SessionSummary],
        definitions: [AgentDefinition],
        connections: [ConnectorConnection],
        deliveries: [EventDelivery],
        occurrences: [ScheduleOccurrence],
        runs: [OrchestrationRun] = [],
        accounts: [ProviderAccount],
        readyAccountIDs: Set<UUID>,
        accountModels: [UUID: [String]] = [:],
        accountStatuses: [UUID: ProviderAccountStatus] = [:],
        localModels: [String] = [],
        runningSessionIDs: Set<String> = [],
        attentionSessionIDs: Set<String> = [],
        attentionItems: [AttentionItem] = [],
        workspace: String? = nil,
        resultTranscript: ResultTranscript? = nil
    ) -> Self {
        let ownedSessions = sessions.filter { $0.savedAgentProfileID == profile.id }
        let ownedIDs = Set(ownedSessions.map(\.id))
        let references = Set(ownedSessions.compactMap { $0.agentReference(in: definitions) })
        let foreignReferences = Set(sessions.filter {
            $0.savedAgentProfileID != profile.id
        }.compactMap { $0.agentReference(in: definitions) })
        // A re-assigned automation may have chats owned by two profiles. Its
        // records must then name an owned chat, rather than borrowing all history.
        func owns(_ reference: AgentInspectorAgent, sessionID: String?) -> Bool {
            guard references.contains(reference) else { return false }
            if let sessionID = sessionID?.nilIfEmpty { return ownedIDs.contains(sessionID) }
            return !foreignReferences.contains(reference)
        }
        let ownDeliveries = deliveries.filter {
            owns(.init(kind: .event, agentID: $0.triggerID), sessionID: $0.conversationSessionID)
        }
        let ownOccurrences = occurrences.filter {
            owns(.init(kind: .schedule, agentID: $0.scheduleID), sessionID: $0.sessionID)
        }
        let ownRuns = runs.filter { $0.sessionID.map(ownedIDs.contains) == true }
        var ownedAttention = attentionItems.filter { item in
            if let id = item.sessionID { return ownedIDs.contains(id) }
            guard let id = item.automationID else { return false }
            let kind: AgentInspectorAgent.Kind
            switch item.automationKind {
            case "event": kind = .event
            case "schedule": kind = .schedule
            default: return false
            }
            return owns(.init(kind: kind, agentID: id), sessionID: nil)
        }
        // A loaded waiting run is current evidence even while the attention
        // inbox is unavailable or paginated. Historical failures are different:
        // only the recovery inbox decides whether those still require action.
        let representedRunIDs = Set(ownedAttention.compactMap(\.runID))
        for run in ownRuns where run.state.hasPrefix("waiting_") && !representedRunIDs.contains(run.id) {
            ownedAttention.append(AttentionItem(id: "waiting-run:\(run.id)", kind: "waiting_run", group: .decisions,
                sessionID: run.sessionID, runID: run.id,
                title: AgentInspectorCopy.state(run.state),
                detail: "This run is waiting for your decision. Review its request to continue.",
                timestamp: run.updatedAt, actions: ["open_chat"]))
        }
        let runsByID = Dictionary(ownRuns.map { ($0.id, $0) }, uniquingKeysWith: {
            $0.updatedAt >= $1.updatedAt ? $0 : $1
        })
        let sources: [String: (sessionID: String?, runID: String?)] = Dictionary(
            ownDeliveries.map { ("event:\($0.id)", ($0.conversationSessionID, $0.runID)) }
                + ownOccurrences.map { ("schedule:\($0.id)", ($0.sessionID, $0.runID)) },
            uniquingKeysWith: { first, _ in first }
        )
        var activity: [AgentActivityRecord] = []
        let merged = AgentActivityRecord.merged(deliveries: ownDeliveries,
            occurrences: ownOccurrences, definitions: definitions)
        for record in merged {
            guard let runID = sources[record.id]?.runID, let run = runsByID[runID] else {
                activity.append(record)
                continue
            }
            let timestamp: Double = max(record.timestamp, run.completedAt ?? run.updatedAt)
            let receiptState: String = record.delivery?.state ?? record.state
            let effectiveState = AgentInspectorCopy.effectiveActivityState(deliveryState: receiptState, runState: run.state)
            let error: String? = record.error ?? run.recoveryReason
            activity.append(AgentActivityRecord(id: record.id, agent: record.agent, agentName: record.agentName,
                title: record.title, sourceTitle: record.sourceTitle, timestamp: timestamp,
                state: effectiveState, error: error, context: record.context, delivery: record.delivery))
        }
        activity.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
        let route = route(profile: profile, accounts: accounts, readyAccountIDs: readyAccountIDs,
            models: accountModels, statuses: accountStatuses, localModels: localModels)
        var issues: [Issue] = []
        if let issue = route.issue {
            issues.append(Issue(id: "route", title: "Model access needs attention", detail: issue,
                action: route.accountID.map { .manageAccount($0) } ?? .editAgent))
        }
        let ownedDefinitions = definitions.filter { definition in
            let reference = AgentInspectorAgent(definition)
            guard references.contains(reference) else { return false }
            if let target = definition.trigger?.targetSessionID.nilIfEmpty {
                return ownedIDs.contains(target)
            }
            return !foreignReferences.contains(reference)
        }
        let connectionIDs = Set(ownedDefinitions.compactMap(\.trigger).flatMap {
            [$0.connectionID] + $0.actionConnectionIDs
        }.filter { !$0.isEmpty })
        let sourceRows: [Connection] = connectionIDs.sorted().map { id in
            guard let connection = connections.first(where: { $0.id == id }) else {
                return Connection(id: id, title: "Missing connection", detail: "Reconnect this automation’s service.",
                    isHealthy: false, action: .connections)
            }
            let healthy = connection.enabled && connection.health.lowercased() == "connected"
                && connection.lastError?.nilIfEmpty == nil
            return Connection(id: id, title: connection.displayName.nilIfEmpty ?? connection.kind.title,
                detail: !connection.enabled ? "Disabled" : connection.lastError?.nilIfEmpty
                    ?? connection.health.replacingOccurrences(of: "_", with: " ").capitalized,
                isHealthy: healthy, action: .connections)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for connection in sourceRows where connection.needsAttention {
            issues.append(Issue(id: "connection:\(connection.id)", title: connection.title,
                detail: connection.detail, action: connection.action))
        }
        let automationRows: [Automation] = ownedDefinitions.map { definition -> Automation in
            let reference = AgentInspectorAgent(definition)
            let latest = activity.first { $0.agent == reference }
            let busy = latest?.isInProgress == true || ownedSessions.contains {
                $0.agentReference(in: definitions) == reference && runningSessionIDs.contains($0.id)
            }
            // A failed receipt is durable history. Clearing its warning or
            // reconnecting an account must not re-create a current model error.
            let error = definition.lastError?.nilIfEmpty
            let latestRunID = latest.flatMap { sources[$0.id]?.runID }
            let unresolved = ownedAttention.contains { item in
                (item.automationID == reference.agentID
                    && item.automationKind == (definition.isSchedule ? "schedule" : "event"))
                    || (latestRunID != nil && item.runID == latestRunID)
            }
            let waiting = latest.map { $0.state.hasPrefix("waiting_") } == true
            let attention = error != nil || unresolved || waiting
            let status: String
            if busy { status = "Working" }
            else if attention { status = "Needs attention" }
            else if !definition.enabled { status = "Paused" }
            else { status = definition.isSchedule ? "Scheduled" : "Listening" }
            let detail: String
            if let error { detail = error }
            else if !definition.enabled { detail = "Automatic starts are paused." }
            else if let schedule = definition.schedule {
                detail = AgentOverviewFormatting.rule(schedule.rule) + " · " + schedule.timezone
            } else { detail = "Waiting for matching events." }
            if let error {
                issues.append(Issue(id: "automation:\(reference.id)", title: "\(definition.name) · Saved warning",
                    detail: "Last recorded warning: " + error,
                    action: .automation(reference)))
            } else if waiting && !unresolved, let latest {
                issues.append(Issue(id: "automation:\(reference.id)", title: definition.name,
                    detail: latest.statusTitle, action: .activity(latest.context)))
            }
            return Automation(reference: reference, definition: definition, enabled: definition.enabled,
                statusTitle: status, detail: detail,
                nextRunAt: definition.enabled ? definition.schedule?.nextRunDate : nil,
                latestActivity: latest, needsAttention: attention, isBusy: busy, action: .automation(reference))
        }.sorted { (lhs: Automation, rhs: Automation) in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            if lhs.isBusy != rhs.isBusy { return lhs.isBusy }
            return lhs.definition.name.localizedCaseInsensitiveCompare(rhs.definition.name) == .orderedAscending
        }
        var results: [LatestResult] = activity.map { record -> LatestResult in
            let source = sources[record.id]
            return LatestResult(id: record.id, title: record.agentName, state: record.state,
                statusTitle: record.statusTitle, summary: resultSummary(state: record.state, error: record.error),
                timestamp: Date(timeIntervalSince1970: record.timestamp), isInProgress: record.isInProgress,
                needsAttention: record.needsAttention, action: .activity(record.context),
                sessionID: source?.sessionID, runID: source?.runID)
        }
        let recordedRuns = Set(results.compactMap(\.runID))
        for run in ownRuns where !recordedRuns.contains(run.id) {
            let session = ownedSessions.first { $0.id == run.sessionID }
            let progress = inProgress(run.state)
            let attention = requiresAttention(run.state)
            results.append(LatestResult(id: "run:\(run.id)", title: session?.displayTitle ?? "Agent run",
                state: run.state, statusTitle: AgentInspectorCopy.state(run.state),
                summary: resultSummary(state: run.state, error: run.recoveryReason),
                timestamp: Date(timeIntervalSince1970: run.completedAt ?? run.updatedAt),
                isInProgress: progress, needsAttention: attention,
                action: session.map { .chat($0.id) }, sessionID: run.sessionID, runID: run.id))
        }
        results.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
        var latestResult: LatestResult? = results.first
        let newestChat = ownedSessions.sorted {
            $0.mtime == $1.mtime ? $0.id < $1.id : $0.mtime > $1.mtime
        }.first
        // A newer manual conversation may have a result even if the run list
        // has never loaded. Do not substitute it for a newer automation run.
        let newerManualChat = newestChat.flatMap { chat -> SessionSummary? in
            guard chat.agentReference(in: definitions) == nil,
                  latestResult == nil || chat.mtime > latestResult!.timestamp.timeIntervalSince1970 else { return nil }
            return chat
        }
        let resultSessionID: String?
        if let chat = newerManualChat { resultSessionID = chat.id }
        else if let result = latestResult { resultSessionID = result.sessionID }
        else { resultSessionID = newestChat?.id }
        if let resultTranscript, let resultSessionID, ownedIDs.contains(resultSessionID) {
            let exactResult = newerManualChat == nil && latestResult?.sessionID == resultSessionID ? latestResult : nil
            let answer: HistoryMessage?
            if let exactResult, exactResult.runID?.nilIfEmpty == nil || exactResult.state != "completed" {
                // A failed receipt can retain a link to a previous completed
                // handoff. Keep its outcome and error, not that run's answer.
                answer = nil
            } else {
                answer = resultTranscript.lastAnswer(profileID: profile.id, sessionID: resultSessionID,
                                                      runID: exactResult?.runID)
            }
            if let answer {
                let summary = String(answer.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
                if let result = exactResult {
                    latestResult = LatestResult(id: result.id, title: result.title, state: result.state,
                        statusTitle: result.statusTitle, summary: summary, timestamp: result.timestamp,
                        isInProgress: result.isInProgress, needsAttention: result.needsAttention,
                        action: result.action, sessionID: result.sessionID, runID: result.runID)
                } else if let chat = ownedSessions.first(where: { $0.id == resultSessionID }) {
                    latestResult = LatestResult(id: "response:\(chat.id):\(answer.itemID ?? answer.runID ?? "latest")",
                        title: chat.displayTitle, state: "saved_response", statusTitle: "Saved response",
                        summary: summary, timestamp: Date(timeIntervalSince1970: chat.mtime),
                        isInProgress: false, needsAttention: false, action: .chat(chat.id),
                        sessionID: chat.id, runID: answer.runID)
                }
            }
        }
        for item in ownedAttention where item.group != .configuration {
            let action: Action?
            if let id = item.workflowExecutionID { action = .attention(.workflow(id)) }
            else if let id = item.runID { action = .attention(.run(id)) }
            else { action = item.sessionID.map(Action.chat) }
            let detail = item.group == .recoveries
                ? "An earlier attempt stopped. Review it to retry or dismiss that attempt; future automatic starts are controlled separately."
                : item.detail
            issues.append(Issue(id: "attention:\(item.id)",
                title: item.group == .recoveries ? "Earlier work needs review" : item.title,
                detail: detail, action: action))
        }
        let representedSessionIDs = Set(ownedAttention.compactMap(\.sessionID))
        let attentionIDs = ownedIDs.intersection(attentionSessionIDs).subtracting(representedSessionIDs)
        if let session = ownedSessions.first(where: { attentionIDs.contains($0.id) }) {
            issues.append(Issue(id: "conversation", title: "A conversation needs you",
                detail: "Review what needs attention in \(session.displayTitle).", action: .chat(session.id)))
        }
        let busy = !ownedIDs.isDisjoint(with: runningSessionIDs)
            || ownRuns.contains { inProgress($0.state) } || automationRows.contains(where: \.isBusy)
        let attention = !issues.isEmpty
        let paused = !automationRows.isEmpty && automationRows.allSatisfy { !$0.enabled }
        let status: Status = attention ? .needsAttention : busy ? .working
            : paused ? .paused : route.isVerified ? .ready : .unverified
        let title: String
        let detail: String
        switch status {
        case .needsAttention:
            title = "Needs attention"
            let onlyEarlierWork = issues.allSatisfy { $0.id.hasPrefix("attention:") }
                && ownedAttention.allSatisfy { $0.group == .recoveries }
            detail = onlyEarlierWork && route.isVerified
                ? "Connected now. Earlier work still needs review."
                : issues.first?.detail ?? "Review this agent’s activity."
        case .working: title = "Working"; detail = "This agent has work in progress."
        case .paused: title = "Automations paused"; detail = "Its automatic starts are paused. You can still open a chat."
        case .ready: title = "Ready"; detail = automationRows.isEmpty ? "Ready for a new chat. No automations configured." : "Ready for chats and automatic starts."
        case .unverified: title = "Configured"; detail = route.detail
        }
        let canonicalWorkspace = workspace.map(SessionSummary.canonicalWorkspacePath)
        let chats = ownedSessions.filter {
            !$0.isArchived && (canonicalWorkspace.map($0.belongsToWorkspace) ?? true)
        }.sorted { $0.mtime == $1.mtime ? $0.id < $1.id : $0.mtime > $1.mtime }
        return Self(profileID: profile.id, status: status, statusTitle: title, detail: detail,
            isBusy: busy, needsAttention: attention, route: route, issues: issues,
            connections: sourceRows, automations: automationRows, latestResult: latestResult,
            resultSessionID: resultSessionID, chats: chats)
    }

    private static func route(profile: AgentProfile, accounts: [ProviderAccount], readyAccountIDs: Set<UUID>,
        models: [UUID: [String]], statuses: [UUID: ProviderAccountStatus], localModels: [String]) -> Route {
        let model = profile.model
        if case .localOllama = profile.route {
            let issue = !profile.isConfigured ? "Choose an exact model for this agent."
                : !localModels.isEmpty && !localModels.contains(model) ? "The saved local model is not installed." : nil
            return Route(accountID: nil, title: "Local Ollama", model: model,
                detail: localModels.isEmpty ? "Local model availability has not been checked." : "Local model installed",
                issue: issue, isVerified: issue == nil && !localModels.isEmpty)
        }
        guard case .providerAccount(let id) = profile.route else {
            return Route(accountID: nil, title: "Model account", model: model,
                detail: "Choose a model account.", issue: "Choose a model account.", isVerified: false)
        }
        guard let account = accounts.first(where: { $0.id == id }) else {
            return Route(accountID: id, title: "Missing account", model: model,
                detail: "The saved model account is unavailable.", issue: "Reconnect this agent’s saved model account.", isVerified: false)
        }
        var issue: String?
        var verified = false
        var detail = "Connection not checked"
        switch statuses[id] {
        case .connected, .signedIn: verified = true; detail = "Connected"
        case .keySaved: detail = "Key saved · Connection not checked"
        case .some(let status): issue = status.summary; detail = status.summary
        case nil: break // Missing observations are unknown, not evidence that access failed.
        }
        if !profile.isConfigured { issue = "Choose an exact model for this agent." }
        else if account.kind.listsModels, let catalog = models[id], !catalog.isEmpty,
                !catalog.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }) {
            issue = "\(account.displayName) does not report \(model). Choose an available model."
        }
        return Route(accountID: id, title: account.displayName, model: model,
            detail: detail, issue: issue, isVerified: verified && issue == nil)
    }

    private static func inProgress(_ state: String) -> Bool {
        ["pending", "queued", "claiming", "dispatching", "planning", "running", "advancing", "awaiting_run"].contains(state)
    }
    private static func requiresAttention(_ state: String) -> Bool {
        ["failed", "interrupted", "waiting_permission", "waiting_computer", "waiting_dispatch_approval", "waiting_approval"].contains(state)
    }
    private static func resultSummary(state: String, error: String?) -> String {
        if state != "skipped", let error = error?.nilIfEmpty { return error }
        if state == "completed" { return "No saved output loaded for this run. Open the chat to read its result." }
        if state == "skipped" { return "This occurrence was skipped." }
        return AgentInspectorCopy.state(state) + ". Open its activity for details."
    }
}
