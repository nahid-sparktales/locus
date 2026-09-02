import Foundation

/// One persistent agent, projected for the inspector's Agent tab: its trigger
/// and source, the chats it owns, and the events that reached it. Assembled
/// from state the app already holds — the automation model, the session
/// catalog, and the worker table — so the tab needs no backend call of its
/// own and the projection is testable as a pure function.
struct AgentOverview: Equatable {
    enum Status: Equatable {
        case active
        /// The person paused it. Nothing is wrong.
        case paused
        /// Locus stopped it after a failure and will not restart it by itself.
        case stopped
        /// Still listening, but the last event did not get through.
        case failing
        case fired
        /// The chats survived but their trigger was deleted or never loaded.
        case missingTrigger

        var title: String {
            switch self {
            case .active: "Active"
            case .paused: "Paused"
            case .stopped: "Stopped"
            case .failing: "Last event failed"
            case .fired: "Fired"
            case .missingTrigger: "No trigger"
            }
        }

        var detail: String {
            switch self {
            case .active: "Listening for matching events"
            case .paused: "You paused this agent. Events are recorded but no chat starts."
            case .stopped: "Locus stopped this agent after a failure. Resume to start listening again."
            case .failing: "The last event did not get through. The agent is still listening."
            case .fired: "This one-shot alert already fired; re-arm to watch again"
            case .missingTrigger: "The trigger behind these chats no longer exists"
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
        /// Every delivery is dispatched into the trigger's one target chat, so
        /// exactly one of an agent's chats receives events and the rest are
        /// side conversations a person started.
        var isEventTarget = false

        var id: String { session.id }
    }

    struct Event: Identifiable, Equatable {
        let delivery: EventDelivery

        var id: String { delivery.id }

        var title: String {
            let subject = delivery.event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !subject.isEmpty { return subject }
            let text = delivery.event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(120)) }
            return delivery.event.eventType.isEmpty ? "Event" : delivery.event.eventType
        }

        /// Delivery states are backend strings; the terminal ones are stable
        /// (`TERMINAL_STATES` in runstore), the rest describe dispatch.
        var stateTitle: String {
            delivery.state.replacingOccurrences(of: "_", with: " ").capitalized
        }

        var isFailed: Bool {
            delivery.error != nil || ["failed", "interrupted", "cancelled"].contains(delivery.state)
        }

        var isInFlight: Bool {
            ["pending", "claiming", "queued", "dispatching", "running"].contains(delivery.state)
        }

        var canRetry: Bool {
            ["failed", "interrupted", "cancelled"].contains(delivery.state)
        }

        var observedPrice: String? {
            guard delivery.event.eventType == "price.quote" else { return nil }
            return delivery.event.data["price"]?.string
        }

        var receivedAt: Date { Date(timeIntervalSince1970: delivery.receivedAt) }
    }

    struct Fact: Identifiable, Equatable {
        let label: String
        let value: String
        var isWarning = false

        var id: String { label }
    }

    let triggerID: String
    let name: String
    let trigger: EventTrigger?
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

    var currentChat: Chat? { chats.first(where: \.isCurrent) }
    /// The chat every event lands in, when it still exists.
    var eventChat: Chat? { chats.first(where: \.isEventTarget) }
    /// The agent has chats but its event chat is gone — deleting it leaves the
    /// trigger pointing at nothing, which no amount of resuming repairs.
    var hasLostEventChat: Bool { trigger != nil && eventChat == nil }
    var runningChatCount: Int { chats.filter(\.isRunning).count }
    var isPriceAlert: Bool { trigger?.triggerKind == .price }
    var canRearm: Bool { isPriceAlert && trigger?.runtimeState.fired == true }

    static let recentEventLimit = 8

    // MARK: Resolution

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
        let ownChats = sessions
            .filter { $0.agentTriggerID == triggerID }
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
                isEventTarget: session.id == targetSessionID
            )
        }
        let name = trigger?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ownChats.compactMap { $0.agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
            ?? ownChats.first?.displayTitle
            ?? "Agent"
        let connection = trigger.flatMap { trigger in
            connections.first { $0.id == trigger.connectionID }
        }
        let ownDeliveries = deliveries
            .filter { $0.triggerID == triggerID }
            .sorted { $0.receivedAt > $1.receivedAt }
        let events = ownDeliveries.prefix(recentEventLimit).map(Event.init)
        let failedCount = ownDeliveries.filter { Event(delivery: $0).isFailed }.count
        let lastEventAt = trigger?.lastEventAt.map { Date(timeIntervalSince1970: $0) }
            ?? ownDeliveries.first.map { Date(timeIntervalSince1970: $0.receivedAt) }

        let status = status(for: trigger)
        let workspaceName = ownChats.compactMap(\.workspacePath).first
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
        if let workspaceName {
            facts.append(Fact(label: "Workspace", value: workspaceName))
        }
        if let trigger {
            facts.append(Fact(
                label: "Created",
                value: Date(timeIntervalSince1970: trigger.createdAt)
                    .formatted(date: .abbreviated, time: .omitted)
            ))
        }

        return AgentOverview(
            triggerID: triggerID,
            name: name,
            trigger: trigger,
            connection: connection,
            status: status,
            summary: summary(trigger: trigger, connection: connection),
            instruction: trigger?.instruction.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            filters: trigger.map { filterChips(for: $0.filters, kind: $0.triggerKind) } ?? [],
            facts: facts,
            chats: chats,
            events: Array(events),
            eventCount: ownDeliveries.count,
            failedEventCount: failedCount,
            lastEventAt: lastEventAt,
            lastError: (trigger?.lastError?.nilIfEmpty ?? connection?.lastError?.nilIfEmpty)
                .map(humanizedError),
            priceState: trigger.flatMap { priceState(for: $0, now: now) }
        )
    }

    /// The backend records only `enabled` and a free-text `last_error`, but the
    /// pair carries four distinct meanings. A disabled trigger with an error is
    /// one Locus switched off itself (`pause_event_trigger` on a dispatch
    /// failure); a disabled trigger without one is a deliberate pause.
    static func status(for trigger: EventTrigger?) -> Status {
        guard let trigger else { return .missingTrigger }
        if let error = trigger.lastError, !error.isEmpty {
            return trigger.enabled ? .failing : .stopped
        }
        if trigger.triggerKind == .price, trigger.runtimeState.fired == true { return .fired }
        return trigger.enabled ? .active : .paused
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
            "the target chat model is unavailable":
                "The model this agent runs on is no longer available.",
            "the agent provider is not supported":
                "The model provider this agent runs on is no longer supported.",
            "this configuration does not own a dedicated agent":
                "This configuration has no agent chat of its own.",
            "capability is disabled: event_triggers":
                "Event agents are turned off in this build of Locus.",
        ]
        if let match = known[trimmed.lowercased()] { return match }
        guard let first = trimmed.first else { return trimmed }
        let sentence = first.uppercased() + trimmed.dropFirst()
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    static func summary(trigger: EventTrigger?, connection: ConnectorConnection?) -> String {
        guard let trigger else { return "Persistent agent" }
        var parts = [connection?.kind.title ?? "No source", trigger.triggerKind.title]
        parts.append(trigger.mode.title)
        return parts.joined(separator: " · ")
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
/// trigger the backend knows, whether or not it has started a chat yet.
struct AgentFleetEntry: Identifiable, Equatable {
    let trigger: EventTrigger
    let connection: ConnectorConnection?
    let status: AgentOverview.Status
    let chatCount: Int
    let runningChatCount: Int
    let latestChat: SessionSummary?
    let lastEventAt: Date?

    var id: String { trigger.id }
    var summary: String { AgentOverview.summary(trigger: trigger, connection: connection) }
}

enum AgentFleet {
    static func entries(
        triggers: [EventTrigger],
        connections: [ConnectorConnection],
        sessions: [SessionSummary],
        runningSessionIDs: Set<String>
    ) -> [AgentFleetEntry] {
        let chatsByTrigger = Dictionary(grouping: sessions.filter(\.isAgentChat)) {
            $0.agentTriggerID ?? ""
        }
        return triggers
            .map { trigger in
                let chats = (chatsByTrigger[trigger.id] ?? []).sorted { $0.mtime > $1.mtime }
                return AgentFleetEntry(
                    trigger: trigger,
                    connection: connections.first { $0.id == trigger.connectionID },
                    status: AgentOverview.status(for: trigger),
                    chatCount: chats.count,
                    runningChatCount: chats.filter { runningSessionIDs.contains($0.id) }.count,
                    latestChat: chats.first,
                    lastEventAt: trigger.lastEventAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
            .sorted { lhs, rhs in
                // Attention first, then the most recently active agent.
                if lhs.status.isWarning != rhs.status.isWarning { return lhs.status.isWarning }
                let left = lhs.lastEventAt ?? .distantPast
                let right = rhs.lastEventAt ?? .distantPast
                if left != right { return left > right }
                return lhs.trigger.name.localizedCaseInsensitiveCompare(rhs.trigger.name) == .orderedAscending
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

    /// The companion to `relative`: a clock time for today, a date otherwise,
    /// short enough for a stat tile's caption.
    static func absolute(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func chatCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "chat" : "chats")"
    }

    static func eventCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "event" : "events")"
    }
}
