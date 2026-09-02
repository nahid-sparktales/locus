import Foundation
import XCTest
@testable import Locus

final class AgentOverviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        _ id: String,
        triggerID: String? = "weather",
        name: String? = "Weather",
        title: String? = nil,
        age: TimeInterval
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            name: "\(id).jsonl",
            preview: "Check the forecast",
            mtime: now.timeIntervalSince1970 - age,
            size: 100,
            title: title,
            cwd: "/tmp/weather-workspace",
            agentTriggerID: triggerID,
            agentName: name
        )
    }

    private func trigger(
        id: String = "weather",
        kind: EventTriggerKind = .event,
        enabled: Bool = true,
        lastError: String? = nil,
        filters: EventTriggerFilters = EventTriggerFilters(),
        runtimeState: PriceTriggerState = PriceTriggerState(),
        actions: [String] = ["gmail-1"],
        lastEventAt: Double? = nil
    ) -> EventTrigger {
        EventTrigger(
            id: id,
            name: "Weather watch",
            connectionID: "gmail-1",
            targetSessionID: "chat-new",
            instruction: "Summarize the forecast and flag storms.",
            mode: .work,
            triggerKind: kind,
            filters: filters,
            runtimeState: runtimeState,
            actionConnectionIDs: actions,
            enabled: enabled,
            createdAt: now.timeIntervalSince1970 - 86_400 * 3,
            updatedAt: now.timeIntervalSince1970 - 60,
            lastEventAt: lastEventAt,
            lastRunID: nil,
            lastError: lastError
        )
    }

    private var gmail: ConnectorConnection {
        ConnectorConnection(
            id: "gmail-1",
            kind: .gmail,
            displayName: "Work Gmail",
            publicConfig: [:],
            cursor: [:],
            enabled: true,
            health: "connected",
            lastError: nil,
            lastPolledAt: now.timeIntervalSince1970 - 30,
            createdAt: now.timeIntervalSince1970 - 86_400,
            updatedAt: now.timeIntervalSince1970 - 30
        )
    }

    private func scheduledTask(
        id: String = "morning",
        name: String = "Morning review",
        enabled: Bool = true,
        lastError: String? = nil,
        rule: ScheduleRule = ScheduleRule(kind: .weekdays, hour: 9, minute: 30),
        nextRunAt: Double? = nil,
        lastRunAt: Double? = nil,
        environment: ChatExecutionEnvironment = .local
    ) -> ScheduledTask {
        ScheduledTask(
            id: id,
            name: name,
            prompt: "Review the workspace and summarize what changed.",
            workspaceRoot: "/tmp/review-workspace",
            mode: .work,
            executionEnvironment: environment,
            runner: .solo,
            teamID: nil,
            teamName: nil,
            provider: "ollama",
            providerAccountID: nil,
            model: "qwen3:8b",
            timezone: TimeZone.current.identifier,
            rule: rule,
            enabled: enabled,
            nextRunAt: nextRunAt,
            createdAt: now.timeIntervalSince1970 - 86_400 * 7,
            updatedAt: now.timeIntervalSince1970 - 60,
            lastRunAt: lastRunAt,
            lastRunID: nil,
            lastError: lastError
        )
    }

    private func occurrence(
        _ id: String,
        scheduleID: String = "morning",
        state: String,
        age: TimeInterval,
        trigger: String = "due",
        sessionID: String? = "morning-chat",
        error: String? = nil
    ) -> ScheduleOccurrence {
        let when = now.timeIntervalSince1970 - age
        return ScheduleOccurrence(
            id: id,
            scheduleID: scheduleID,
            scheduleName: "Morning review",
            scheduledFor: when,
            trigger: trigger,
            state: state,
            sessionID: sessionID,
            runID: state == "queued" ? "run-\(id)" : nil,
            error: error,
            createdAt: when,
            updatedAt: when + 5
        )
    }

    private func delivery(
        _ id: String,
        state: String,
        age: TimeInterval,
        subject: String = "Storm warning",
        sessionID: String? = "chat-new",
        error: String? = nil
    ) -> EventDelivery {
        let received = now.timeIntervalSince1970 - age
        return EventDelivery(
            id: id,
            triggerID: "weather",
            sourceEventID: "src-\(id)",
            source: .gmail,
            receivedAt: received,
            occurredAt: received - 5,
            event: InboundEvent(
                source: .gmail,
                sourceEventID: "src-\(id)",
                eventType: "email.received",
                occurredAt: received - 5,
                actor: [:],
                subject: subject,
                text: "",
                recipients: [],
                labels: [],
                attachments: [],
                data: [:]
            ),
            state: state,
            runState: nil,
            attempt: 1,
            sessionID: sessionID,
            runID: nil,
            error: error,
            createdAt: received,
            updatedAt: received
        )
    }

    // MARK: Resolution

    func testOverviewGroupsTheAgentsChatsNewestFirstAndMarksCurrentAndRunning() {
        let sessions = [
            session("chat-old", age: 7_200),
            session("chat-new", age: 60),
            session("other", triggerID: "other-agent", name: "Other", age: 10),
            session("plain", triggerID: nil, name: nil, age: 5),
        ]
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(),
            connections: [gmail],
            actionConnections: [gmail],
            sessions: sessions,
            deliveries: [],
            currentSessionID: "chat-new",
            runningSessionIDs: ["chat-old"],
            startedAt: ["chat-old": now.addingTimeInterval(-30)],
            now: now
        )

        XCTAssertEqual(overview.name, "Weather watch")
        XCTAssertEqual(overview.chats.map(\.id), ["chat-new", "chat-old"])
        XCTAssertEqual(overview.currentChat?.id, "chat-new")
        XCTAssertTrue(overview.chats[1].isRunning)
        XCTAssertEqual(overview.chats[1].startedAt, now.addingTimeInterval(-30))
        XCTAssertEqual(overview.runningChatCount, 1)
        XCTAssertEqual(overview.status, .active)
        XCTAssertEqual(overview.summary, "Gmail · Incoming Event · Work")
        XCTAssertEqual(overview.filters, ["Every incoming event"])
        XCTAssertEqual(overview.facts.map(\.label), ["Source", "Connection", "Runs as", "May act through", "Workspace", "Created"])
        XCTAssertEqual(overview.facts[0].value, "Work Gmail · Gmail")
        XCTAssertEqual(overview.facts[1].value, "Connected")
        XCTAssertFalse(overview.facts[1].isWarning)
        XCTAssertEqual(overview.facts[3].value, "Work Gmail")
        XCTAssertEqual(overview.facts[4].value, "weather-workspace")
        XCTAssertNil(overview.priceState)
        XCTAssertNil(overview.lastError)
    }

    func testOverviewWithoutATriggerStillNamesTheAgentFromItsChats() {
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: nil,
            connections: [],
            sessions: [session("chat-new", age: 60)],
            deliveries: [],
            currentSessionID: "chat-new",
            runningSessionIDs: [],
            now: now
        )

        XCTAssertEqual(overview.name, "Weather")
        XCTAssertEqual(overview.status, .missingTrigger)
        XCTAssertTrue(overview.status.isWarning)
        XCTAssertEqual(overview.summary, "Persistent agent")
        XCTAssertTrue(overview.filters.isEmpty)
        XCTAssertEqual(overview.facts.map(\.label), ["Workspace"])
        XCTAssertEqual(overview.instruction, "")
    }

    func testStatusSeparatesAPersonPausingFromLocusStoppingTheAgent() {
        XCTAssertEqual(AgentOverview.status(for: nil as EventTrigger?), .missingTrigger)
        XCTAssertEqual(AgentOverview.status(for: nil as AgentDefinition?), .missingTrigger)
        // enabled, no error: listening.
        XCTAssertEqual(AgentOverview.status(for: trigger()), .active)
        // disabled, no error: someone pressed Pause.
        XCTAssertEqual(AgentOverview.status(for: trigger(enabled: false)), .paused)
        // disabled with an error: a dispatch failure switched it off.
        XCTAssertEqual(
            AgentOverview.status(for: trigger(enabled: false, lastError: "poll failed")),
            .stopped
        )
        // enabled with an error: one event failed, the agent still listens.
        XCTAssertEqual(
            AgentOverview.status(for: trigger(lastError: "poll failed")),
            .failing
        )

        XCTAssertTrue(AgentOverview.Status.stopped.needsResume)
        XCTAssertFalse(AgentOverview.Status.paused.needsResume)
        XCTAssertFalse(AgentOverview.Status.failing.needsResume)
        // A deliberate pause is not a problem to be flagged; the rest are.
        XCTAssertFalse(AgentOverview.Status.paused.isWarning)
        XCTAssertTrue(AgentOverview.Status.stopped.isWarning)
        XCTAssertTrue(AgentOverview.Status.failing.isWarning)
        XCTAssertFalse(AgentOverview.Status.fired.isWarning)

        var fired = PriceTriggerState()
        fired.fired = true
        XCTAssertEqual(
            AgentOverview.status(for: trigger(kind: .price, enabled: false, runtimeState: fired)),
            .fired
        )
        XCTAssertEqual(
            AgentOverview.status(for: trigger(kind: .event, runtimeState: fired)),
            .active,
            "only price alerts fire"
        )
    }

    func testBackendDispatchDetailsAreTranslatedBeforeTheyBecomeAStatusLine() {
        XCTAssertEqual(
            AgentOverview.humanizedError("target chat not found"),
            "This agent's chat was deleted, so events have nowhere to go."
        )
        XCTAssertEqual(
            AgentOverview.humanizedError("the target chat model is unavailable"),
            "The model this agent runs on is no longer available."
        )
        // Anything Locus does not recognize is still shown, as a sentence.
        XCTAssertEqual(AgentOverview.humanizedError("gmail token expired"), "Gmail token expired.")
        XCTAssertEqual(AgentOverview.humanizedError("Already fine."), "Already fine.")
        XCTAssertEqual(AgentOverview.humanizedError("   "), "")
    }

    func testOnlyTheTriggersTargetChatIsMarkedAsReceivingEvents() {
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(),
            connections: [gmail],
            sessions: [session("chat-new", age: 60), session("chat-old", age: 7_200)],
            deliveries: [],
            currentSessionID: "chat-old",
            runningSessionIDs: [],
            now: now
        )

        // `trigger()` targets "chat-new".
        XCTAssertEqual(overview.eventChat?.id, "chat-new")
        XCTAssertEqual(overview.chats.filter(\.isEventTarget).map(\.id), ["chat-new"])
        XCTAssertFalse(overview.hasLostEventChat)

        // Delete that chat and the agent has nowhere to put events.
        let orphaned = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(),
            connections: [gmail],
            sessions: [session("chat-old", age: 7_200)],
            deliveries: [],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )
        XCTAssertNil(orphaned.eventChat)
        XCTAssertTrue(orphaned.hasLostEventChat)
        XCTAssertFalse(orphaned.chats.isEmpty, "the side conversations survive")

        // Chats without a trigger cannot claim to receive anything.
        let noTrigger = AgentOverview.resolve(
            triggerID: "weather",
            trigger: nil,
            connections: [],
            sessions: [session("chat-new", age: 60)],
            deliveries: [],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )
        XCTAssertNil(noTrigger.eventChat)
        XCTAssertFalse(noTrigger.hasLostEventChat)
    }

    func testRecentEventsAreNewestFirstCappedAndCounted() {
        var deliveries: [EventDelivery] = []
        for index in 0..<12 {
            let failed = index % 4 == 0
            deliveries.append(delivery(
                "d\(index)",
                state: failed ? "failed" : "completed",
                age: TimeInterval(index * 600),
                error: failed ? "boom" : nil
            ))
        }
        let foreign = delivery("foreign", state: "completed", age: 1).replacingTrigger("other")
        let mixed: [EventDelivery] = deliveries.shuffled() + [foreign]
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(),
            connections: [gmail],
            sessions: [],
            deliveries: mixed,
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )

        XCTAssertEqual(overview.events.count, AgentOverview.recentEventLimit)
        XCTAssertEqual(overview.events.first?.id, "d0")
        XCTAssertEqual(overview.events.last?.id, "d7")
        XCTAssertEqual(overview.eventCount, 12)
        XCTAssertEqual(overview.failedEventCount, 3)
        XCTAssertEqual(overview.lastEventAt, now, "falls back to the newest delivery when the trigger has no lastEventAt")
        XCTAssertTrue(overview.events[0].isFailed)
        XCTAssertTrue(overview.events[0].canRetry)
        XCTAssertFalse(overview.events[1].isFailed)
        XCTAssertEqual(overview.events[1].stateTitle, "Completed")
    }

    func testTriggerLastEventWinsOverDeliveryTimestamps() {
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(lastEventAt: now.timeIntervalSince1970 - 10),
            connections: [gmail],
            sessions: [],
            deliveries: [delivery("d0", state: "completed", age: 3_600)],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )
        XCTAssertEqual(overview.lastEventAt, now.addingTimeInterval(-10))
    }

    func testEventTitleFallsBackFromSubjectToTextToType() {
        var noSubject = delivery("d1", state: "completed", age: 1, subject: "")
        XCTAssertEqual(AgentOverview.Event(delivery: noSubject).title, "email.received")
        noSubject = noSubject.replacingText("  Body text here  ")
        XCTAssertEqual(AgentOverview.Event(delivery: noSubject).title, "Body text here")
        XCTAssertEqual(AgentOverview.Event(delivery: delivery("d2", state: "queued", age: 1)).title, "Storm warning")
        XCTAssertTrue(AgentOverview.Event(delivery: delivery("d3", state: "queued", age: 1)).isInFlight)
    }

    // MARK: Schedules

    func testAScheduledAgentResolvesFromItsScheduleAndOccurrences() {
        let primary = SessionSummary(
            id: "morning-chat", name: "morning-chat.jsonl", preview: "", mtime: now.timeIntervalSince1970 - 60,
            size: 10, title: "Morning review", cwd: "/tmp/review-workspace",
            agentTriggerID: "morning", agentName: "Morning review", agentPrimary: true,
            model: "qwen3:8b", provider: "ollama"
        )
        let side = SessionSummary(
            id: "morning-side", name: "morning-side.jsonl", preview: "", mtime: now.timeIntervalSince1970 - 30,
            size: 10, title: "Chat 2", cwd: "/tmp/review-workspace",
            agentTriggerID: "morning", agentName: "Morning review"
        )
        let task = scheduledTask(
            nextRunAt: now.timeIntervalSince1970 + 3_600,
            lastRunAt: now.timeIntervalSince1970 - 600
        )
        let overview = AgentOverview.resolve(
            agentID: "morning",
            definition: .schedule(task),
            connections: [],
            sessions: [primary, side],
            deliveries: [],
            occurrences: [
                occurrence("o-old", state: "failed", age: 90_000, error: "The model is not installed."),
                occurrence("o-new", state: "queued", age: 600),
                occurrence("foreign", scheduleID: "other", state: "queued", age: 1),
            ],
            currentSessionID: "morning-side",
            runningSessionIDs: [],
            now: now
        )

        XCTAssertEqual(overview.name, "Morning review")
        XCTAssertEqual(overview.status, .active)
        XCTAssertEqual(overview.summary, "Schedule · Weekdays at 09:30 · Work")
        XCTAssertEqual(overview.instruction, "Review the workspace and summarize what changed.")
        XCTAssertEqual(overview.filters, ["Next in 1h"], "the cadence heads the card; chips add the rest")
        XCTAssertTrue(overview.canRunNow)
        XCTAssertFalse(overview.canRearm)
        XCTAssertNil(overview.priceState)

        // The primary flag marks the chat every run continues; the side chat
        // shares the identity and nothing else.
        XCTAssertEqual(overview.eventChat?.id, "morning-chat")
        XCTAssertEqual(overview.chats.map(\.id), ["morning-side", "morning-chat"])
        XCTAssertEqual(overview.chats.filter(\.isEventTarget).map(\.id), ["morning-chat"])

        // Occurrences stand in for deliveries: newest first, own schedule only.
        XCTAssertEqual(overview.events.map(\.id), ["o-new", "o-old"])
        XCTAssertEqual(overview.eventCount, 2)
        XCTAssertEqual(overview.failedEventCount, 1)
        XCTAssertTrue(overview.events[1].isFailed)
        XCTAssertFalse(overview.events[1].canRetry, "schedules run again on their own; there is no retry")
        XCTAssertTrue(overview.events[0].isInFlight)
        XCTAssertTrue(overview.events[0].title.hasPrefix("Scheduled run · "))
        XCTAssertEqual(overview.events[0].sourceSymbol, "calendar.badge.clock")
        XCTAssertEqual(overview.lastEventAt, now.addingTimeInterval(-600), "the schedule's own last run wins")

        XCTAssertEqual(
            overview.facts.map(\.label),
            ["Runs as", "Runner", "Environment", "Model", "Next run", "Workspace", "Created"]
        )
        XCTAssertEqual(overview.facts[1].value, "Solo")
        XCTAssertEqual(overview.facts[2].value, "Local")
        XCTAssertEqual(overview.facts[3].value, "qwen3:8b")
        XCTAssertEqual(overview.facts[5].value, "review-workspace")
    }

    func testScheduleStatusUsesTheSameFourStatesAsTriggers() {
        XCTAssertEqual(AgentOverview.status(for: .schedule(scheduledTask())), .active)
        XCTAssertEqual(AgentOverview.status(for: .schedule(scheduledTask(enabled: false))), .paused)
        XCTAssertEqual(
            AgentOverview.status(for: .schedule(scheduledTask(enabled: false, lastError: "Model removed"))),
            .stopped
        )
        XCTAssertEqual(
            AgentOverview.status(for: .schedule(scheduledTask(lastError: "The workspace is gone"))),
            .failing
        )
        let paused = AgentOverview.resolve(
            agentID: "morning", definition: .schedule(scheduledTask(enabled: false)),
            connections: [], sessions: [], deliveries: [], currentSessionID: "",
            runningSessionIDs: [], now: now
        )
        XCTAssertEqual(paused.filters, ["Paused"])
        XCTAssertEqual(paused.facts.first { $0.label == "Next run" }?.value, "Paused")
    }

    func testASkippedRunIsNotAFailureOfTheAgent() {
        // Two runs of one schedule overlapping is a normal outcome: the slot
        // passes, the agent keeps working, and nothing needs a person.
        let overview = AgentOverview.resolve(
            agentID: "morning",
            definition: .schedule(scheduledTask(lastRunAt: now.timeIntervalSince1970 - 600)),
            connections: [],
            sessions: [],
            deliveries: [],
            occurrences: [
                occurrence(
                    "o-skip", state: "skipped", age: 600,
                    error: "Skipped: the previous run in this agent's chat was still in progress."
                ),
            ],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )

        XCTAssertEqual(overview.status, .active)
        XCTAssertEqual(overview.failedEventCount, 0)
        XCTAssertFalse(overview.events[0].isFailed)
        XCTAssertFalse(overview.events[0].isInFlight)
        XCTAssertTrue(overview.events[0].isSkipped)
        XCTAssertEqual(overview.events[0].stateTitle, "Skipped")
    }

    func testAgentCopySaysRunsForSchedulesAndEventsForTriggers() {
        let schedule = AgentDefinition.schedule(scheduledTask())
        let trigger = AgentDefinition.trigger(trigger(id: "mail"))

        XCTAssertEqual(schedule.vocabulary, .runs)
        XCTAssertEqual(trigger.vocabulary, .events)
        XCTAssertEqual(
            AgentOverview.Status.failing.title(for: schedule.vocabulary), "Last run failed"
        )
        XCTAssertEqual(
            AgentOverview.Status.failing.title(for: trigger.vocabulary), "Last event failed"
        )
        XCTAssertEqual(
            AgentOverview.Status.failing.title(for: .events), "Last event failed",
            "an event agent never reports a run"
        )
        for status in [AgentOverview.Status.active, .paused, .stopped, .failing] {
            XCTAssertFalse(
                status.detail(for: schedule.vocabulary).localizedCaseInsensitiveContains("event"),
                "a schedule has runs, not events: \(status)"
            )
        }
    }

    func testAScheduleThatWillNotRunAgainStillSaysSo() {
        // A one-shot schedule that has fired has no cadence chip, no worktree
        // and no foreign timezone; an empty chip row would read as a blank gap.
        let task = scheduledTask(
            rule: ScheduleRule(kind: .once, hour: 9, minute: 30),
            nextRunAt: nil
        )
        XCTAssertEqual(AgentOverview.scheduleChips(for: task, now: now), ["No further runs"])
    }

    func testScheduleRulesReadAsSentences() {
        XCTAssertEqual(AgentOverviewFormatting.rule(ScheduleRule(kind: .daily, hour: 7, minute: 5)), "Daily at 07:05")
        XCTAssertEqual(AgentOverviewFormatting.rule(ScheduleRule(kind: .weekdays, hour: 18, minute: 0)), "Weekdays at 18:00")
        XCTAssertEqual(
            AgentOverviewFormatting.rule(ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 4)),
            "Weekly on Friday at 09:00",
            "weekdays are Monday-based, matching the backend"
        )
        XCTAssertEqual(
            AgentOverviewFormatting.rule(ScheduleRule(kind: .interval, every: 15, unit: .minutes)),
            "Every 15 minutes"
        )
        XCTAssertEqual(
            AgentOverviewFormatting.rule(ScheduleRule(kind: .interval, every: 1, unit: .hours)),
            "Every hour"
        )
        let at = now.timeIntervalSince1970
        XCTAssertEqual(
            AgentOverviewFormatting.rule(ScheduleRule(kind: .once, at: at)),
            "Once on " + now.formatted(date: .abbreviated, time: .shortened)
        )
        XCTAssertEqual(AgentOverviewFormatting.upcoming(now.addingTimeInterval(90), now: now), "in 1m")
        XCTAssertEqual(AgentOverviewFormatting.upcoming(now.addingTimeInterval(-5), now: now), "overdue")
    }

    func testFleetListsSchedulesBesideTriggersUnderOneOrdering() {
        var stoppedSchedule = scheduledTask(id: "nightly", name: "Nightly", enabled: false, lastError: "boom")
        stoppedSchedule.name = "Nightly"
        let entries = AgentFleet.entries(
            triggers: [trigger(id: "weather", lastEventAt: now.timeIntervalSince1970 - 60)],
            connections: [gmail],
            schedules: [
                scheduledTask(id: "morning", lastRunAt: now.timeIntervalSince1970 - 30),
                stoppedSchedule,
            ],
            sessions: [
                SessionSummary(
                    id: "m1", name: "m1.jsonl", preview: "", mtime: now.timeIntervalSince1970,
                    size: 1, cwd: "/tmp", agentTriggerID: "morning", agentName: "Morning review",
                    agentPrimary: true
                ),
            ],
            runningSessionIDs: ["m1"]
        )
        XCTAssertEqual(entries.map(\.id), ["nightly", "morning", "weather"])
        XCTAssertEqual(entries[0].status, .stopped)
        XCTAssertEqual(entries[1].summary, "Schedule · Weekdays at 09:30 · Work")
        XCTAssertEqual(entries[1].chatCount, 1)
        XCTAssertEqual(entries[1].runningChatCount, 1)
        XCTAssertNil(entries[1].connection)
        XCTAssertEqual(entries[2].name, "Weather watch")
    }

    @MainActor
    func testAgentDefinitionsAndEventChatOwnershipCoverBothKinds() {
        let model = AppModel(startImmediately: false)
        model.eventAutomations.seedForUITesting(connections: [gmail], triggers: [trigger()], deliveries: [])
        model.schedule.seedForUITesting(tasks: [scheduledTask()])
        model.sessions = [
            session("chat-new", age: 60),
            SessionSummary(
                id: "morning-chat", name: "morning-chat.jsonl", preview: "", mtime: 1, size: 1,
                cwd: "/tmp", agentTriggerID: "morning", agentName: "Morning review", agentPrimary: true
            ),
            SessionSummary(
                id: "morning-side", name: "morning-side.jsonl", preview: "", mtime: 1, size: 1,
                cwd: "/tmp", agentTriggerID: "morning", agentName: "Morning review"
            ),
            session("plain", triggerID: nil, name: nil, age: 5),
        ]

        XCTAssertEqual(model.agentDefinition(for: "weather")?.trigger?.id, "weather")
        XCTAssertEqual(model.agentDefinition(for: "morning")?.schedule?.id, "morning")
        XCTAssertNil(model.agentDefinition(for: "gone"))
        XCTAssertNil(model.agentDefinition(for: nil))

        let byID = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        // The trigger's target chat is its event chat even without the flag.
        XCTAssertEqual(model.agentOwningEventChat(byID["chat-new"]!)?.name, "Weather watch")
        XCTAssertEqual(model.agentOwningEventChat(byID["morning-chat"]!)?.name, "Morning review")
        XCTAssertNil(model.agentOwningEventChat(byID["morning-side"]!), "side chats are not protected")
        XCTAssertNil(model.agentOwningEventChat(byID["plain"]!))
    }

    // MARK: Filters

    func testFilterChipsSpellOutEverySavedFilter() {
        var filters = EventTriggerFilters()
        filters.senders = ["boss@example.com", " "]
        filters.recipients = ["me@example.com"]
        filters.labels = ["INBOX"]
        filters.subjectContains = ["invoice"]
        filters.hasAttachments = true
        filters.chatIDs = ["-100"]
        filters.senderIDs = ["42"]
        filters.commandPrefixes = ["/triage"]
        filters.messageTypes = ["text"]
        filters.eventNames = ["order.created"]
        filters.predicates = [
            EventFilterPredicate(path: "order.status", operation: .equals, value: "paid"),
            EventFilterPredicate(path: "order.total", operation: .exists, value: ""),
            EventFilterPredicate(path: "note", operation: .contains, value: "urgent"),
            EventFilterPredicate(path: "  ", operation: .equals, value: "ignored"),
        ]

        XCTAssertEqual(AgentOverview.filterChips(for: filters, kind: .event), [
            "From boss@example.com",
            "To me@example.com",
            "Label INBOX",
            "Subject contains invoice",
            "Has attachments",
            "Chat -100",
            "Sender 42",
            "Command /triage",
            "Type text",
            "Event order.created",
            "order.status = paid",
            "order.total exists",
            "note contains urgent",
        ])
    }

    func testPriceConditionLeadsThePriceAlertChips() {
        var filters = EventTriggerFilters()
        var condition = PriceCondition()
        condition.displaySymbol = "BTC/USD"
        condition.providerSymbol = "BTCUSDT"
        condition.comparison = .crossesBelow
        condition.threshold = "60000.50"
        condition.quoteCurrency = "USD"
        condition.lifecycle = .rearm
        filters.priceCondition = condition
        filters.eventNames = ["price.quote"]

        let chips = AgentOverview.filterChips(for: filters, kind: .price)
        let threshold = Decimal(string: "60000.50")!
            .formatted(.number.precision(.fractionLength(0...8)))
        XCTAssertEqual(chips.first, "BTC/USD crosses below \(threshold) USD")
        XCTAssertEqual(chips[1], "Fire on every recross")
        XCTAssertEqual(chips.last, "Event price.quote")
        XCTAssertEqual(
            AgentOverview.filterChips(for: EventTriggerFilters(), kind: .price),
            ["No price condition"]
        )
    }

    func testPriceStateReportsQuoteSideAndFiring() {
        var state = PriceTriggerState()
        state.lastPrice = "64120.00"
        state.lastSide = "above"
        state.lastQuoteAt = now.timeIntervalSince1970 - 180
        state.fired = true
        state.lastFiredAt = now.timeIntervalSince1970 - 3_600
        var filters = EventTriggerFilters()
        filters.priceCondition = PriceCondition()
        let priceTrigger = trigger(kind: .price, filters: filters, runtimeState: state)

        XCTAssertEqual(
            AgentOverview.priceState(for: priceTrigger, now: now),
            "Last quote 64120.00 USD · currently above · 3m ago · fired 1h ago"
        )
        XCTAssertEqual(AgentOverview.priceState(for: trigger(kind: .price), now: now), "No quote yet")
        XCTAssertNil(AgentOverview.priceState(for: trigger(kind: .event), now: now))

        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: priceTrigger,
            connections: [gmail],
            sessions: [],
            deliveries: [],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )
        XCTAssertTrue(overview.canRearm)
        XCTAssertEqual(overview.status, .fired)
    }

    func testMissingConnectionAndPollErrorsSurfaceAsWarnings() {
        let overview = AgentOverview.resolve(
            triggerID: "weather",
            trigger: trigger(lastError: "Gmail token expired"),
            connections: [],
            sessions: [],
            deliveries: [],
            currentSessionID: "",
            runningSessionIDs: [],
            now: now
        )
        XCTAssertEqual(overview.status, .failing, "the trigger is still enabled")
        XCTAssertEqual(
            overview.lastError,
            "Gmail token expired.",
            "the raw backend detail is sentence-cased before it is shown"
        )
        XCTAssertEqual(overview.facts[0].value, "Missing connection")
        XCTAssertTrue(overview.facts[0].isWarning)
        XCTAssertEqual(overview.facts.map(\.label), ["Source", "Runs as", "May act through", "Created"])
        XCTAssertEqual(overview.facts[2].value, "Nothing — ingestion only")
    }

    // MARK: Fleet

    func testFleetSortsAttentionFirstThenRecencyThenName() {
        let quiet = trigger(id: "b-quiet")
        var recent = trigger(id: "c-recent", lastEventAt: now.timeIntervalSince1970 - 60)
        recent.name = "Recent"
        var broken = trigger(id: "a-broken", lastError: "boom")
        broken.name = "Broken"
        var older = trigger(id: "d-older", lastEventAt: now.timeIntervalSince1970 - 3_600)
        older.name = "Older"
        var alsoQuiet = trigger(id: "e-quiet")
        alsoQuiet.name = "Alpha quiet"

        let entries = AgentFleet.entries(
            triggers: [quiet, older, recent, broken, alsoQuiet],
            connections: [gmail],
            sessions: [
                session("r1", triggerID: "c-recent", age: 10),
                session("r2", triggerID: "c-recent", age: 100),
                session("q1", triggerID: "b-quiet", age: 5),
            ],
            runningSessionIDs: ["r2"]
        )

        XCTAssertEqual(
            entries.map(\.id),
            ["a-broken", "c-recent", "d-older", "e-quiet", "b-quiet"],
            "attention, then recency, then name for agents that never fired"
        )
        XCTAssertEqual(entries[1].chatCount, 2)
        XCTAssertEqual(entries[1].runningChatCount, 1)
        XCTAssertEqual(entries[1].latestChat?.id, "r1")
        XCTAssertEqual(entries[0].status, .failing)
        XCTAssertNil(entries[3].lastEventAt)
        XCTAssertNil(entries[4].lastEventAt)
        XCTAssertEqual(entries[2].summary, "Gmail · Incoming Event · Work")
    }

    // MARK: Formatting

    func testRelativeTimeBuckets() {
        XCTAssertEqual(AgentOverviewFormatting.relative(now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(AgentOverviewFormatting.relative(now.addingTimeInterval(-90), now: now), "1m ago")
        XCTAssertEqual(AgentOverviewFormatting.relative(now.addingTimeInterval(-3_599), now: now), "59m ago")
        XCTAssertEqual(AgentOverviewFormatting.relative(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(AgentOverviewFormatting.relative(now.addingTimeInterval(-86_400 * 3), now: now), "3d ago")
        let old = now.addingTimeInterval(-86_400 * 30)
        XCTAssertEqual(
            AgentOverviewFormatting.relative(old, now: now),
            old.formatted(date: .abbreviated, time: .omitted)
        )
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        XCTAssertEqual(
            AgentOverviewFormatting.absolute(noon.addingTimeInterval(-600), now: noon),
            noon.addingTimeInterval(-600).formatted(date: .omitted, time: .shortened)
        )
        XCTAssertEqual(
            AgentOverviewFormatting.absolute(noon.addingTimeInterval(-86_400), now: noon),
            noon.addingTimeInterval(-86_400).formatted(date: .abbreviated, time: .omitted)
        )
        XCTAssertEqual(
            AgentOverviewFormatting.absolute(old, now: now),
            old.formatted(date: .abbreviated, time: .omitted)
        )
        XCTAssertEqual(AgentOverviewFormatting.chatCount(1), "1 chat")
        XCTAssertEqual(AgentOverviewFormatting.eventCount(3), "3 events")
    }

    // MARK: Inspector sync

    @MainActor
    func testAgentsModeSwapsAnOpenOverviewForTheAgentTabAndAskTakesItBack() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = [.plan]
        model.inspectorTab = .plan
        model.inspectorCollapsed = false

        model.sidebarDestination = .agents
        XCTAssertEqual(model.inspectorTab, .agent)
        XCTAssertEqual(model.openInspectorTabs, [.plan, .agent])
        XCTAssertFalse(model.inspectorCollapsed)

        model.sidebarDestination = .ask
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertEqual(model.openInspectorTabs, [.plan])
        XCTAssertFalse(model.inspectorCollapsed)
    }

    @MainActor
    func testAgentsModeLeavesACollapsedOrBusyInspectorAlone() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = [.plan]
        model.inspectorTab = .plan
        model.inspectorCollapsed = true

        model.sidebarDestination = .agents
        XCTAssertTrue(model.inspectorCollapsed, "a collapsed panel is a preference")
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertEqual(model.openInspectorTabs, [.plan])

        model.sidebarDestination = .ask
        model.inspectorCollapsed = false
        model.selectInspectorTab(.terminal)
        model.sidebarDestination = .agents
        XCTAssertEqual(model.inspectorTab, .terminal, "only an Overview panel is swapped for the agent")
        XCTAssertFalse(model.openInspectorTabs.contains(.agent))
    }

    @MainActor
    func testLeavingAgentsModeWhileOnAnotherTabOnlyDropsTheAgentTab() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = [.plan]
        model.inspectorTab = .plan
        model.inspectorCollapsed = false
        model.sidebarDestination = .agents
        model.selectInspectorTab(.terminal)
        XCTAssertEqual(model.openInspectorTabs, [.plan, .agent, .terminal])

        model.sidebarDestination = .ask
        XCTAssertEqual(model.inspectorTab, .terminal)
        XCTAssertEqual(model.openInspectorTabs, [.plan, .terminal])
    }

    @MainActor
    func testLeavingAgentsModeKeepsACollapsedPanelCollapsed() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = [.plan]
        model.inspectorTab = .plan
        model.inspectorCollapsed = false
        model.sidebarDestination = .agents
        XCTAssertEqual(model.inspectorTab, .agent)
        model.inspectorCollapsed = true

        model.sidebarDestination = .ask
        XCTAssertTrue(model.inspectorCollapsed, "leaving Agents mode must not reopen the panel")
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertEqual(model.openInspectorTabs, [.plan])
        XCTAssertEqual(model.settings.inspectorLastTab, InspectorTab.plan.rawValue)
    }

    @MainActor
    func testLeavingAgentsModeUnderJustChatMovesTheSelectionWithoutOpening() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = [.plan]
        model.inspectorTab = .plan
        model.inspectorCollapsed = false
        model.sidebarDestination = .agents
        model.setJustChatEnabled(true)
        XCTAssertTrue(model.inspectorCollapsed)

        model.sidebarDestination = .ask
        XCTAssertEqual(model.inspectorTab, .plan)
        XCTAssertFalse(model.openInspectorTabs.contains(.agent))
        XCTAssertTrue(model.inspectorCollapsed)
    }

    func testRelaunchNeverRestoresTheAgentTab() {
        var settings = AppSettings()
        settings.inspectorLastTab = InspectorTab.agent.rawValue
        settings.inspectorOpenTabs = [
            InspectorTab.plan.rawValue,
            InspectorTab.agent.rawValue,
            InspectorTab.terminal.rawValue,
        ]
        XCTAssertEqual(settings.resolvedInspectorTab, .plan)
        XCTAssertEqual(settings.resolvedInspectorOpenTabs, [.plan, .terminal])
        XCTAssertEqual(settings.resolvedRestoredInspectorTab, .plan)
    }

    @MainActor
    func testConfigureAgentDeepLinksCarryTheTriggerAndTab() {
        let model = AppModel(startImmediately: false)
        let priceTrigger = trigger(id: "btc", kind: .price)
        model.presentConfigureAgent(focusing: priceTrigger, tab: .runHistory)
        XCTAssertTrue(model.configureAgentPresented)
        XCTAssertEqual(model.configureAgentTab, .runHistory)
        XCTAssertEqual(model.configureAgentFocusConfigurationID, "price:btc")

        model.dismissConfigureAgent()
        XCTAssertNil(model.configureAgentFocusConfigurationID)

        let eventTrigger = trigger()
        model.editAgentTrigger(eventTrigger, isDedicatedAgent: true)
        XCTAssertTrue(model.configureAgentPresented)
        XCTAssertEqual(
            model.configureAgentPendingTriggerEdit,
            PendingEventTriggerEdit(trigger: eventTrigger, targetSessionID: "chat-new", isDedicatedAgent: true)
        )
        // Mounting the sheet drains the request into the automation editor.
        model.mountPendingConfigureAgentEditor()
        XCTAssertNil(model.configureAgentPendingTriggerEdit)
        XCTAssertEqual(model.eventAutomations.editorDraft?.id, "weather")
        XCTAssertEqual(
            model.eventAutomations.editorDraft?.targetSessionID,
            EventTriggerEditorDraft.dedicatedAgentChat
        )
    }

    @MainActor
    func testNewAgentChatRefusesAnAgentWhoseTriggerWasDeleted() {
        let model = AppModel(startImmediately: false)
        model.sessions = [session("chat-new", age: 60)]
        model.currentSessionID = "chat-new"
        model.eventAutomations.seedForUITesting(
            connections: [], triggers: [trigger(id: "someone-else")], deliveries: []
        )
        model.schedule.seedForUITesting(tasks: [])
        model.newAgentChat()
        XCTAssertFalse(model.configureAgentPresented)
        XCTAssertEqual(model.toastCenter.toast?.message.contains("was deleted"), true)
    }

    @MainActor
    func testAMissingAgentIsNotCalledDeletedBeforeBothStoresHaveAnswered() {
        let model = AppModel(startImmediately: false)
        model.sessions = [session("chat-new", age: 60)]
        model.currentSessionID = "chat-new"
        // Triggers are in; schedules have not answered yet, so an agent that is
        // in neither list may still be a schedule that is on its way.
        model.eventAutomations.seedForUITesting(
            connections: [], triggers: [trigger(id: "someone-else")], deliveries: []
        )

        model.newAgentChat()

        XCTAssertNil(model.toastCenter.toast?.message)
    }

    @MainActor
    func testNewChatFollowsTheSidebarDestination() {
        let model = AppModel(startImmediately: false)
        let agentChat = session("chat-new", age: 60)
        model.sessions = [session("plain", triggerID: nil, name: nil, age: 5), agentChat]
        let snapshot = model.sessionCatalog.snapshot

        XCTAssertEqual(model.agentSession(for: nil, in: snapshot)?.id, "chat-new")
        XCTAssertEqual(model.agentSession(for: "weather", in: snapshot)?.id, "chat-new")
        XCTAssertNil(model.agentSession(for: "missing", in: snapshot))

        model.currentSessionID = "chat-new"
        XCTAssertEqual(model.agentSession(for: nil, in: model.sessionCatalog.snapshot)?.id, "chat-new")
    }

    @MainActor
    func testThePrimaryActionCreatesTheThingEachDestinationIsAbout() {
        let model = AppModel(startImmediately: false)
        model.sessions = [session("chat-new", age: 60)]
        model.currentSessionID = "chat-new"

        // Agents mode: ⌘N opens an empty agent, not another chat.
        model.sidebarDestination = .agents
        model.newChatForSidebarDestination()
        XCTAssertTrue(model.configureAgentPresented)
        XCTAssertEqual(model.configureAgentTab, .configurations)
        XCTAssertEqual(
            model.configureAgentPendingTriggerEdit,
            PendingEventTriggerEdit(
                trigger: nil,
                targetSessionID: "chat-new",
                isDedicatedAgent: false,
                triggerKind: .event
            )
        )

        // Mounting the sheet turns that request into a fresh editor draft.
        model.mountPendingConfigureAgentEditor()
        XCTAssertNil(model.configureAgentPendingTriggerEdit)
        let draft = model.eventAutomations.editorDraft
        XCTAssertNil(draft?.id, "a new agent, not an edit")
        XCTAssertEqual(draft?.triggerKind, .event)
        XCTAssertEqual(draft?.targetSessionID, EventTriggerEditorDraft.dedicatedAgentChat)

        // A price agent can be requested directly.
        model.dismissConfigureAgent()
        model.presentNewAgent(kind: .price)
        model.mountPendingConfigureAgentEditor()
        XCTAssertEqual(model.eventAutomations.editorDraft?.triggerKind, .price)
    }
}

private extension EventDelivery {
    func replacingTrigger(_ triggerID: String) -> EventDelivery {
        EventDelivery(
            id: id, triggerID: triggerID, sourceEventID: sourceEventID, source: source,
            receivedAt: receivedAt, occurredAt: occurredAt, event: event, state: state,
            runState: runState, attempt: attempt, sessionID: sessionID, runID: runID,
            error: error, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    func replacingText(_ text: String) -> EventDelivery {
        var event = event
        event.text = text
        return EventDelivery(
            id: id, triggerID: triggerID, sourceEventID: sourceEventID, source: source,
            receivedAt: receivedAt, occurredAt: occurredAt, event: event, state: state,
            runState: runState, attempt: attempt, sessionID: sessionID, runID: runID,
            error: error, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
