import Foundation

/// The record that wakes an agent. Event and price agents are triggers;
/// scheduled agents are schedules. Both own one dedicated chat that every
/// event or run continues, and both can be paused by a person or stopped by
/// Locus after a failure.
enum AgentDefinition: Equatable {
    case trigger(EventTrigger)
    case schedule(ScheduledTask)

    var id: String {
        switch self {
        case .trigger(let trigger): trigger.id
        case .schedule(let task): task.id
        }
    }

    var name: String {
        switch self {
        case .trigger(let trigger): trigger.name
        case .schedule(let task): task.name
        }
    }

    var enabled: Bool {
        switch self {
        case .trigger(let trigger): trigger.enabled
        case .schedule(let task): task.enabled
        }
    }

    var lastError: String? {
        switch self {
        case .trigger(let trigger): trigger.lastError
        case .schedule(let task): task.lastError
        }
    }

    var mode: WorkMode {
        switch self {
        case .trigger(let trigger): trigger.mode
        case .schedule(let task): task.mode
        }
    }

    var createdAt: Double {
        switch self {
        case .trigger(let trigger): trigger.createdAt
        case .schedule(let task): task.createdAt
        }
    }

    /// When the agent last did something: the last event for a trigger, the
    /// last run for a schedule.
    var lastActivityAt: Double? {
        switch self {
        case .trigger(let trigger): trigger.lastEventAt
        case .schedule(let task): task.lastRunAt
        }
    }

    var trigger: EventTrigger? {
        if case .trigger(let trigger) = self { return trigger }
        return nil
    }

    var schedule: ScheduledTask? {
        if case .schedule(let task) = self { return task }
        return nil
    }

    var isSchedule: Bool { schedule != nil }

    /// The words this kind of agent is described in. A schedule has runs on a
    /// cadence; a trigger has events from a source.
    var vocabulary: Vocabulary { isSchedule ? .runs : .events }

    /// Whichever record carries this agent id, or nothing once it is deleted.
    static func resolve(
        agentID: String?,
        triggers: [EventTrigger],
        schedules: [ScheduledTask]
    ) -> AgentDefinition? {
        guard let agentID, !agentID.isEmpty else { return nil }
        let matches = triggers.filter { $0.id == agentID }.map(AgentDefinition.trigger)
            + schedules.filter { $0.id == agentID }.map(AgentDefinition.schedule)
        return matches.count == 1 ? matches[0] : nil
    }

    /// "Incoming Event", "Price Alert", or "Schedule".
    var kindTitle: String {
        switch self {
        case .trigger(let trigger): trigger.triggerKind.title
        case .schedule: "Schedule"
        }
    }
}

/// What an agent's arrivals are called. A schedule's chat receives runs on a
/// cadence; a trigger's receives events from a source. Every surface that
/// names them reads from here, so the two kinds never borrow each other's
/// words.
struct Vocabulary: Equatable {
    let arrival: String
    let arrivals: String
    let record: String
    let badge: String

    static let events = Vocabulary(
        arrival: "event", arrivals: "events", record: "trigger", badge: "EVENTS"
    )
    static let runs = Vocabulary(
        arrival: "run", arrivals: "runs", record: "schedule", badge: "RUNS"
    )
}

/// One persistent agent, projected for the inspector's Agent tab: what wakes
/// it, the chats it owns, and the events or runs that reached it. Assembled
/// from state the app already holds — the automation and schedule models, the
/// session catalog, and the worker table — so the tab needs no backend call of
/// its own and the projection is testable as a pure function.
struct AgentOverview: Equatable {
    enum Status: Equatable {
        case active
        /// The person paused it. Nothing is wrong.
        case paused
        /// Locus stopped it after a failure and will not restart it by itself.
        case stopped
        /// Still listening, but the last event or run did not get through.
        case failing
        case fired
        /// The chats survived but their trigger or schedule was deleted or
        /// never loaded.
        case missingTrigger

        var title: String {
            switch self {
            case .active: "Active"
            case .paused: "Paused"
            case .stopped: "Stopped"
            case .failing: "Last run failed"
            case .fired: "Fired"
            case .missingTrigger: "No trigger"
            }
        }

        func title(for vocabulary: Vocabulary = .events) -> String {
            self == .failing ? "Last \(vocabulary.arrival) failed" : title
        }

        func detail(for vocabulary: Vocabulary = .events) -> String {
            switch self {
            case .active:
                vocabulary == .runs ? "Running on schedule" : "Listening for matching events"
            case .paused:
                vocabulary == .runs
                    ? "You paused this agent. It skips its scheduled runs until you resume it."
                    : "You paused this agent. Events are recorded but no chat starts."
            case .stopped:
                vocabulary == .runs
                    ? "Locus stopped this agent after a failure. Resume to run on schedule again."
                    : "Locus stopped this agent after a failure. Resume to start listening again."
            case .failing:
                vocabulary == .runs
                    ? "The last run did not get through. The agent is still scheduled."
                    : "The last event did not get through. The agent is still listening."
            case .fired: "This one-shot alert already fired; re-arm to watch again"
            case .missingTrigger: "The \(vocabulary.record) behind these chats no longer exists"
            }
        }

        /// Whether the agent has stopped acting on events. Paused is deliberate
        /// and quiet; stopped and missing are not, and lead the fleet list.
        var isWarning: Bool {
            switch self {
            case .stopped, .failing, .missingTrigger: true
            case .active, .paused, .fired: false
            }
        }

        /// Only a stopped agent needs a person to switch it back on.
        var needsResume: Bool { self == .stopped }
    }

    struct Chat: Identifiable, Equatable {
        let session: SessionSummary
        let isCurrent: Bool
        let isRunning: Bool
        let startedAt: Date?
        /// Every event or run continues the agent's one dedicated chat, so
        /// exactly one of an agent's chats receives them and the rest are side
        /// conversations a person started.
        var isEventTarget = false

        var id: String { session.id }
    }

    /// One thing that reached the agent: an event delivery for a trigger, or
    /// an occurrence for a schedule. Both render through the same row.
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let stateTitle: String
        let isFailed: Bool
        let isInFlight: Bool
        /// A run whose slot passed because the one before it was still going.
        /// Neither a success nor a failure, and it is drawn as neither.
        var isSkipped = false
        let canRetry: Bool
        let observedPrice: String?
        let receivedAt: Date
        let sessionID: String?
        let error: String?
        let attempt: Int
        let matchedTriggerCount: Int
        let sourceSymbol: String
        /// Retry acts on the delivery; schedule occurrences have no retry.
        let delivery: EventDelivery?

        init(delivery: EventDelivery) {
            let subject = delivery.event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = delivery.event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = delivery.event.eventType.isEmpty ? "Event" : delivery.event.eventType
            id = delivery.id
            title = !subject.isEmpty ? subject : (!text.isEmpty ? String(text.prefix(120)) : fallback)
            // Delivery states are backend strings; the terminal ones are stable
            // (`TERMINAL_STATES` in runstore), the rest describe dispatch.
            stateTitle = AgentInspectorCopy.state(delivery.runState ?? delivery.state)
            isFailed = delivery.error != nil
                || ["failed", "interrupted", "cancelled"].contains(delivery.state)
            isInFlight = ["pending", "claiming", "queued", "dispatching", "running"]
                .contains(delivery.state)
            canRetry = ["failed", "interrupted", "cancelled"].contains(delivery.state)
            observedPrice = delivery.event.eventType == "price.quote"
                ? delivery.event.data["price"]?.string : nil
            receivedAt = Date(timeIntervalSince1970: delivery.receivedAt)
            sessionID = delivery.conversationSessionID
            error = delivery.error
            attempt = delivery.attempt
            matchedTriggerCount = delivery.matchedTriggerCount
            sourceSymbol = delivery.source.symbol
            self.delivery = delivery
        }

        init(occurrence: ScheduleOccurrence) {
            let when = Date(timeIntervalSince1970: occurrence.scheduledFor)
            id = occurrence.id
            title = (occurrence.trigger == "manual" ? "Run now" : "Scheduled run")
                + " · " + when.formatted(date: .abbreviated, time: .shortened)
            let skipped = occurrence.state == "skipped"
            isSkipped = skipped
            stateTitle = AgentInspectorCopy.state(occurrence.state)
            // An overlap with the run before it is a normal outcome, not a
            // failure: the agent kept working, this slot simply passed.
            isFailed = !skipped
                && (occurrence.error != nil
                    || ["failed", "interrupted", "cancelled"].contains(occurrence.state))
            isInFlight = ["claiming", "queued", "dispatching", "running"].contains(occurrence.state)
            canRetry = false
            observedPrice = nil
            receivedAt = when
            sessionID = occurrence.sessionID
            error = occurrence.error
            attempt = 1
            matchedTriggerCount = 1
            sourceSymbol = "calendar.badge.clock"
            delivery = nil
        }
    }

    struct Fact: Identifiable, Equatable {
        let label: String
        let value: String
        var isWarning = false

        var id: String { label }
    }

    let agentID: String
    let name: String
    let definition: AgentDefinition?
    let connection: ConnectorConnection?
    let status: Status
    /// "Gmail · Incoming Event · Work" — the one-line identity under the name.
    let summary: String
    let instruction: String
    let filters: [String]
    let facts: [Fact]
    let chats: [Chat]
    let events: [Event]
    let eventCount: Int
    let failedEventCount: Int
    let lastEventAt: Date?
    let lastError: String?
    /// The live side of a price alert: last quote, side, and when it fired.
    let priceState: String?

    var trigger: EventTrigger? { definition?.trigger }
    var schedule: ScheduledTask? { definition?.schedule }
    /// Whether this agent's arrivals are called events or runs.
    var vocabulary: Vocabulary { definition?.vocabulary ?? .events }
    var currentChat: Chat? { chats.first(where: \.isCurrent) }
    /// The chat every event or run lands in, when it still exists.
    var eventChat: Chat? { chats.first(where: \.isEventTarget) }
    /// The agent has chats but its event chat is gone — deleting it leaves the
    /// trigger pointing at nothing, which no amount of resuming repairs.
    var hasLostEventChat: Bool { definition != nil && eventChat == nil }
    var runningChatCount: Int { chats.filter(\.isRunning).count }
    var isPriceAlert: Bool { trigger?.triggerKind == .price }
    var canRearm: Bool { isPriceAlert && trigger?.runtimeState.fired == true }
    var canRunNow: Bool { schedule != nil }
    var purpose: String {
        let firstParagraph = instruction.components(separatedBy: "\n\n").first ?? ""
        return firstParagraph.isEmpty ? summary : firstParagraph
    }

    static let recentEventLimit = 8

    // MARK: Resolution

    /// Trigger-only entry point kept for callers and tests that predate
    /// scheduled agents.
    static func resolve(
        triggerID: String,
        trigger: EventTrigger?,
        connections: [ConnectorConnection],
        actionConnections: [ConnectorConnection] = [],
        sessions: [SessionSummary],
        deliveries: [EventDelivery],
        currentSessionID: String,
        runningSessionIDs: Set<String>,
        startedAt: [String: Date] = [:],
        now: Date = Date()
    ) -> AgentOverview {
        resolve(
            agentID: triggerID,
            definition: trigger.map(AgentDefinition.trigger),
            connections: connections,
            actionConnections: actionConnections,
            sessions: sessions,
            deliveries: deliveries,
            currentSessionID: currentSessionID,
            runningSessionIDs: runningSessionIDs,
            startedAt: startedAt,
            now: now
        )
    }

    static func resolve(
        agentID: String,
        definition: AgentDefinition?,
        ownershipDefinitions: [AgentDefinition]? = nil,
        connections: [ConnectorConnection],
        actionConnections: [ConnectorConnection] = [],
        sessions: [SessionSummary],
        deliveries: [EventDelivery],
        occurrences: [ScheduleOccurrence] = [],
        currentSessionID: String,
        runningSessionIDs: Set<String>,
        startedAt: [String: Date] = [:],
        now: Date = Date()
    ) -> AgentOverview {
        let trigger = definition?.trigger
        let schedule = definition?.schedule
        let ownChats = sessions
            .filter { session in
                guard session.agentTriggerID == agentID else { return false }
                if let ownershipDefinitions, let definition {
                    return session.agentReference(in: ownershipDefinitions) == AgentInspectorAgent(definition)
                }
                guard let definition, let kind = session.agentKind else { return true }
                return kind == (definition.isSchedule ? "schedule" : "event")
            }
            .sorted { lhs, rhs in
                if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
                return lhs.id < rhs.id
            }
        let targetSessionID = trigger?.targetSessionID.nilIfEmpty
        let chats = ownChats.map { session in
            Chat(
                session: session,
                isCurrent: session.id == currentSessionID,
                isRunning: runningSessionIDs.contains(session.id),
                startedAt: startedAt[session.id],
                isEventTarget: session.isAgentEventChat || session.id == targetSessionID
            )
        }
        let name = definition?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ownChats.compactMap { $0.agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
            ?? ownChats.first?.displayTitle
            ?? "Agent"
        let connection = trigger.flatMap { trigger in
            connections.first { $0.id == trigger.connectionID }
        }

        // Every event or run that reached the agent, newest first. The panel
        // shows a handful. These fallback counts describe only loaded rows;
        // the contextual inspector obtains retained-history totals separately.
        let allEvents: [Event]
        let lastEventAt: Date?
        if schedule != nil {
            allEvents = occurrences
                .filter { $0.scheduleID == agentID }
                .sorted { $0.scheduledFor > $1.scheduledFor }
                .map(Event.init(occurrence:))
            lastEventAt = schedule?.lastRunAt.map { Date(timeIntervalSince1970: $0) }
                ?? allEvents.first?.receivedAt
        } else {
            allEvents = deliveries
                .filter { $0.triggerID == agentID }
                .sorted { $0.receivedAt > $1.receivedAt }
                .map(Event.init(delivery:))
            lastEventAt = trigger?.lastEventAt.map { Date(timeIntervalSince1970: $0) }
                ?? allEvents.first?.receivedAt
        }
        let events = Array(allEvents.prefix(recentEventLimit))
        let eventCount = allEvents.count
        let failedCount = allEvents.filter(\.isFailed).count

        let status = status(for: definition)
        let workspaceName = (ownChats.compactMap(\.workspacePath).first ?? schedule?.workspaceRoot)
            .flatMap { $0.nilIfEmpty }
            .map { URL(fileURLWithPath: $0).lastPathComponent }

        var facts: [Fact] = []
        if let trigger {
            let sourceName = connection?.displayName.nilIfEmpty ?? "Missing connection"
            let sourceKind = connection?.kind.title ?? "Source"
            facts.append(Fact(
                label: "Source",
                value: connection == nil ? sourceName : "\(sourceName) · \(sourceKind)",
                isWarning: connection == nil
            ))
            if let connection {
                let health = connection.health.trimmingCharacters(in: .whitespacesAndNewlines)
                let healthy = connection.enabled && health.lowercased() == "connected"
                facts.append(Fact(
                    label: "Connection",
                    value: connection.enabled ? health.capitalized : "Disabled",
                    isWarning: !healthy
                ))
            }
            facts.append(Fact(label: "Runs as", value: trigger.mode.title))
            let actions = actionConnections
                .filter { trigger.actionConnectionIDs.contains($0.id) }
                .map(\.displayName)
            facts.append(Fact(
                label: "May act through",
                value: actions.isEmpty ? "Nothing — ingestion only" : actions.joined(separator: ", ")
            ))
        }
        if let schedule {
            facts.append(Fact(label: "Runs as", value: schedule.mode.title))
            facts.append(Fact(
                label: "Runner",
                value: schedule.runner == .team
                    ? (schedule.teamName?.nilIfEmpty ?? "Team") : "Solo"
            ))
            facts.append(Fact(label: "Environment", value: schedule.executionEnvironment.title))
            facts.append(Fact(
                label: "Model",
                value: schedule.model.nilIfEmpty ?? "Not set",
                isWarning: schedule.model.nilIfEmpty == nil
            ))
            facts.append(Fact(
                label: "Next run",
                value: schedule.nextRunDate.map {
                    AgentOverviewFormatting.absolute($0, now: now)
                } ?? (schedule.enabled ? "Not scheduled" : "Paused")
            ))
        }
        if let workspaceName {
            facts.append(Fact(label: "Workspace", value: workspaceName))
        }
        if let definition {
            facts.append(Fact(
                label: "Created",
                value: Date(timeIntervalSince1970: definition.createdAt)
                    .formatted(date: .abbreviated, time: .omitted)
            ))
        }

        let filters: [String]
        if let trigger {
            filters = filterChips(for: trigger.filters, kind: trigger.triggerKind)
        } else if let schedule {
            filters = scheduleChips(for: schedule, now: now)
        } else {
            filters = []
        }
        let instruction = (trigger?.instruction ?? schedule?.prompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return AgentOverview(
            agentID: agentID,
            name: name,
            definition: definition,
            connection: connection,
            status: status,
            summary: summary(definition: definition, connection: connection),
            instruction: instruction,
            filters: filters,
            facts: facts,
            chats: chats,
            events: events,
            eventCount: eventCount,
            failedEventCount: failedCount,
            lastEventAt: lastEventAt,
            lastError: (definition?.lastError?.nilIfEmpty ?? connection?.lastError?.nilIfEmpty)
                .map(humanizedError),
            priceState: trigger.flatMap { priceState(for: $0, now: now) }
        )
    }

    /// The backend records only `enabled` and a free-text `last_error`, but the
    /// pair carries four distinct meanings. A disabled record with an error is
    /// one Locus switched off itself (a dispatch failure pauses the trigger or
    /// schedule); a disabled record without one is a deliberate pause.
    static func status(for definition: AgentDefinition?) -> Status {
        guard let definition else { return .missingTrigger }
        if let error = definition.lastError, !error.isEmpty {
            return definition.enabled ? .failing : .stopped
        }
        if let trigger = definition.trigger,
           trigger.triggerKind == .price,
           trigger.runtimeState.fired == true {
            return .fired
        }
        return definition.enabled ? .active : .paused
    }

    static func status(for trigger: EventTrigger?) -> Status {
        status(for: trigger.map(AgentDefinition.trigger))
    }

    /// Dispatch failures are re-raised as the agent's status line, so the raw
    /// HTTP detail from the backend would otherwise be what a person reads.
    /// Translate the ones Locus itself produces and leave anything else alone
    /// beyond sentence-casing it.
    static func humanizedError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let known: [String: String] = [
            "target chat not found":
                "This agent's chat was deleted, so events have nowhere to go.",
            "the target chat workspace is unavailable":
                "The agent's workspace folder is missing or was moved.",
            "the target chat checkout is unavailable":
                "The agent's worktree checkout is missing.",
            "the agent's checkout is unavailable":
                "The agent's worktree checkout is missing.",
            "the target chat model is unavailable":
                "The model this agent runs on is no longer available.",
            "the agent provider is not supported":
                "The model provider this agent runs on is no longer supported.",
            "this configuration does not own a dedicated agent":
                "This configuration has no agent chat of its own.",
            "capability is disabled: event_triggers":
                "Event agents are turned off in this build of Locus.",
            "the scheduled workspace is no longer available":
                "The agent's workspace folder is missing or was moved.",
            "scheduled worktrees require a git repository":
                "Worktree runs need the workspace to be a Git repository.",
        ]
        if let match = known[trimmed.lowercased()] { return match }
        guard let first = trimmed.first else { return trimmed }
        let sentence = first.uppercased() + trimmed.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    static func summary(definition: AgentDefinition?, connection: ConnectorConnection?) -> String {
        guard let definition else { return "Persistent agent" }
        switch definition {
        case .trigger(let trigger):
            return [connection?.kind.title ?? "No source", trigger.triggerKind.title, trigger.mode.title]
                .joined(separator: " · ")
        case .schedule(let task):
            return ["Schedule", AgentOverviewFormatting.rule(task.rule), task.mode.title]
                .joined(separator: " · ")
        }
    }

    static func summary(trigger: EventTrigger?, connection: ConnectorConnection?) -> String {
        summary(definition: trigger.map(AgentDefinition.trigger), connection: connection)
    }

    /// Human-readable filter chips. Every populated filter becomes one chip so
    /// the panel says what the editor saved rather than paraphrasing it.
    static func filterChips(for filters: EventTriggerFilters, kind: EventTriggerKind) -> [String] {
        var chips: [String] = []
        if let price = filters.priceCondition, kind == .price {
            chips.append(priceDescription(price))
            chips.append(price.lifecycle.title)
        }
        func list(_ label: String, _ values: [String]) {
            let clean = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !clean.isEmpty else { return }
            chips.append("\(label) \(clean.joined(separator: ", "))")
        }
        list("From", filters.senders)
        list("To", filters.recipients)
        list("Label", filters.labels)
        list("Subject contains", filters.subjectContains)
        if let hasAttachments = filters.hasAttachments {
            chips.append(hasAttachments ? "Has attachments" : "No attachments")
        }
        list("Chat", filters.chatIDs)
        list("Sender", filters.senderIDs)
        list("Command", filters.commandPrefixes)
        list("Type", filters.messageTypes)
        list("Event", filters.eventNames)
        for predicate in filters.predicates {
            let path = predicate.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            switch predicate.operation {
            case .exists: chips.append("\(path) exists")
            case .equals: chips.append("\(path) = \(predicate.value)")
            case .contains: chips.append("\(path) contains \(predicate.value)")
            }
        }
        if chips.isEmpty {
            chips.append(kind == .price ? "No price condition" : "Every incoming event")
        }
        return chips
    }

    /// The equivalent for a schedule: its cadence, when it next fires, and
    /// anything about where it runs that a person would want to know.
    static func scheduleChips(for task: ScheduledTask, now: Date) -> [String] {
        var chips: [String] = []
        if let next = task.nextRunDate, task.enabled {
            chips.append("Next \(AgentOverviewFormatting.upcoming(next, now: now))")
        } else if !task.enabled {
            chips.append("Paused")
        }
        if task.executionEnvironment == .worktree {
            chips.append("Runs in a worktree")
        }
        if task.timezone != TimeZone.current.identifier, !task.timezone.isEmpty {
            chips.append(task.timezone)
        }
        if chips.isEmpty {
            chips.append("No further runs")
        }
        return chips
    }

    static func priceDescription(_ condition: PriceCondition) -> String {
        let symbol = condition.displaySymbol.nilIfEmpty
            ?? condition.providerSymbol.nilIfEmpty
            ?? "Price"
        let threshold = condition.thresholdDecimal.map {
            $0.formatted(.number.precision(.fractionLength(0...8)))
        } ?? condition.threshold
        return "\(symbol) \(condition.comparison.title.lowercased()) \(threshold) \(condition.quoteCurrency)"
    }

    static func priceState(for trigger: EventTrigger, now: Date) -> String? {
        guard trigger.triggerKind == .price else { return nil }
        let state = trigger.runtimeState
        var parts: [String] = []
        if let price = state.lastPrice?.nilIfEmpty {
            let currency = trigger.filters.priceCondition?.quoteCurrency ?? ""
            parts.append("Last quote \(price) \(currency)".trimmingCharacters(in: .whitespaces))
        }
        if let side = state.lastSide?.nilIfEmpty {
            parts.append("currently \(side.replacingOccurrences(of: "_", with: " "))")
        }
        if let quotedAt = state.lastQuoteAt {
            parts.append(AgentOverviewFormatting.relative(
                Date(timeIntervalSince1970: quotedAt), now: now
            ))
        }
        if state.fired == true, let firedAt = state.lastFiredAt {
            parts.append("fired \(AgentOverviewFormatting.relative(Date(timeIntervalSince1970: firedAt), now: now))")
        }
        return parts.isEmpty ? "No quote yet" : parts.joined(separator: " · ")
    }
}

/// One row of the fleet list shown when no single agent is selected: every
/// trigger and schedule the backend knows, whether or not it has a chat yet.
struct AgentFleetEntry: Identifiable, Equatable {
    let definition: AgentDefinition
    let connection: ConnectorConnection?
    let status: AgentOverview.Status
    let chatCount: Int
    let runningChatCount: Int
    let latestChat: SessionSummary?
    let lastEventAt: Date?

    var id: String { definition.id }
    var inspectorID: AgentInspectorAgent { AgentInspectorAgent(definition) }
    var name: String { definition.name }
    var trigger: EventTrigger? { definition.trigger }
    var summary: String { AgentOverview.summary(definition: definition, connection: connection) }
}

enum AgentFleet {
    static func entries(
        triggers: [EventTrigger],
        connections: [ConnectorConnection],
        schedules: [ScheduledTask] = [],
        sessions: [SessionSummary],
        runningSessionIDs: Set<String>
    ) -> [AgentFleetEntry] {
        let definitions = triggers.map(AgentDefinition.trigger) + schedules.map(AgentDefinition.schedule)
        let chatsByAgent = Dictionary(grouping: sessions.filter { $0.agentReference(in: definitions) != nil }) {
            $0.agentReference(in: definitions)!
        }
        return definitions
            .map { definition in
                let chats = (chatsByAgent[AgentInspectorAgent(definition)] ?? []).sorted { $0.mtime > $1.mtime }
                return AgentFleetEntry(
                    definition: definition,
                    connection: definition.trigger.flatMap { trigger in
                        connections.first { $0.id == trigger.connectionID }
                    },
                    status: AgentOverview.status(for: definition),
                    chatCount: chats.count,
                    runningChatCount: chats.filter { runningSessionIDs.contains($0.id) }.count,
                    latestChat: chats.first,
                    lastEventAt: definition.lastActivityAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
            .sorted { lhs, rhs in
                // Attention first, then the most recently active agent.
                if lhs.status.isWarning != rhs.status.isWarning { return lhs.status.isWarning }
                let left = lhs.lastEventAt ?? .distantPast
                let right = rhs.lastEventAt ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

enum AgentOverviewFormatting {
    /// Short relative time for a panel column: "just now", "4m ago", "3h ago",
    /// "2d ago", then a calendar date. Deterministic given `now`, unlike
    /// `RelativeDateTimeFormatter`, so tests can pin it.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return date.formatted(date: .abbreviated, time: .shortened) }
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The forward-looking twin of `relative`: "in 4m", "in 3h", "in 2d",
    /// then a date. A past date reads as overdue rather than negative.
    static func upcoming(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 0 { return "overdue" }
        if seconds < 60 { return "in under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h" }
        let days = hours / 24
        if days < 7 { return "in \(days)d" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The companion to `relative`: a clock time for today, a date otherwise,
    /// short enough for a stat tile's caption.
    static func absolute(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A schedule's cadence in words. Times are written as saved (HH:mm),
    /// which keeps the output stable across locales and lets tests pin it.
    static func rule(_ rule: ScheduleRule) -> String {
        let time = String(format: "%02d:%02d", rule.hour ?? 0, rule.minute ?? 0)
        switch rule.kind {
        case .once:
            if let at = rule.at {
                return "Once on " + Date(timeIntervalSince1970: at)
                    .formatted(date: .abbreviated, time: .shortened)
            }
            return "Once"
        case .daily:
            return "Daily at \(time)"
        case .weekdays:
            return "Weekdays at \(time)"
        case .weekly:
            return "Weekly on \(weekdayName(rule.weekday ?? 0)) at \(time)"
        case .interval:
            let every = max(rule.every ?? 1, 1)
            let unit = rule.unit ?? .hours
            let noun = every == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue
            return every == 1 ? "Every \(noun)" : "Every \(every) \(noun)"
        }
    }

    /// Schedules store Monday-based weekdays (0 = Monday), the Python
    /// convention the backend evaluates against.
    static func weekdayName(_ mondayBased: Int) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names[max(0, min(mondayBased, names.count - 1))]
    }

    static func chatCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "chat" : "chats")"
    }

    static func eventCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "event" : "events")"
    }
}
