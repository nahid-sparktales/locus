import AppKit
import SwiftUI

/// The Agent tab. With an agent selected in the sidebar, footer, or through
/// one of its chats, it shows that whole agent — who it is, what wakes it,
/// what it may do, every chat it owns, and the events that reached it — with
/// the controls that matter day to day: a new chat, pause, re-arm, edit. With
/// no agent selected it shows the fleet, so Agent mode always has something
/// to say.
struct InspectorAgentTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel

    var body: some View {
        AgentInspectorPanel(
            automation: model.eventAutomations,
            schedule: schedule,
            sessionCatalog: sessionCatalog,
            inspector: model.agentInspector
        )
        .environmentObject(model)
    }
}

private struct AgentInspectorPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var schedule: ScheduleModel
    @ObservedObject var sessionCatalog: SessionCatalogModel
    @ObservedObject var inspector: AgentInspectorModel

    private var inspectedAgentID: String? { model.inspectedAgentID }

    var body: some View {
        Group {
            switch inspector.context {
            case .fleet:
                AgentFleetView(entries: fleet, automation: automation)
            case .agent(let reference):
                if model.inspectorAgentDefinition(reference) != nil || (automation.hasLoaded && schedule.hasLoaded) {
                    AgentDetailView(
                        overview: overview(for: reference), automation: automation,
                        inspector: inspector, reference: reference
                    ).id(reference)
                } else {
                    VStack(spacing: 12) {
                        ProgressView("Loading agent…")
                        AgentInspectorLoadStatus(inspector: inspector)
                    }
                }
            case .chat, .event, .occurrence, .run:
                AgentInspectorDetailView(inspector: inspector, context: inspector.context)
                    .id(inspector.context)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocusTheme.paperDeep)
        .foregroundStyle(LocusTheme.ink)
        .font(.locus(size: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent overview")
        .accessibilityIdentifier("agentOverview")
        // Deliveries and trigger state change without a chat event, so the
        // panel keeps itself current while it is on screen. The selected
        // context owns this task and the model rejects stale responses.
        // Fixtures carry their own state and have no backend to ask.
        .onAppear {
            if inspector.context == .fleet, !inspector.hasSelectedContext,
               let reference = model.inspectedAgentReference {
                inspector.show(.agent(reference))
            }
        }
        .task(id: inspector.context) {
            guard !model.isUITesting else {
                model.seedAgentInspectorContextForUITesting()
                return
            }
            await refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await refreshAll()
            }
        }
    }

    /// Both stores, and the current schedule agent's run history, which the
    /// schedule model only loads on request.
    private func refreshAll() async {
        async let automations: Void = automation.refresh(announceFailure: false)
        async let schedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
        async let detail: Void = inspector.refresh(backend: model.backend)
        _ = await (automations, schedules, detail)
    }

    private func overview(for reference: AgentInspectorAgent) -> AgentOverview {
        AgentOverview.resolve(
            agentID: reference.agentID,
            definition: model.inspectorAgentDefinition(reference),
            ownershipDefinitions: model.agentDefinitions,
            connections: automation.connections,
            actionConnections: automation.connections,
            sessions: sessionCatalog.snapshot.sessions.filter { $0.agentReference(in: model.agentDefinitions) == reference },
            deliveries: inspector.snapshot.history?.deliveries ?? automation.deliveries,
            occurrences: inspector.snapshot.history?.occurrences
                ?? schedule.occurrencesBySchedule[reference.agentID] ?? [],
            currentSessionID: model.currentSessionID,
            runningSessionIDs: model.runningChatSessionIDs,
            startedAt: model.runningChatStartTimes
        )
    }

    private var fleet: [AgentFleetEntry] {
        AgentFleet.entries(
            triggers: automation.triggers,
            connections: automation.connections,
            schedules: schedule.scheduledTasks,
            sessions: sessionCatalog.snapshot.sessions,
            runningSessionIDs: model.runningChatSessionIDs
        )
    }
}

// MARK: - Detail

private struct AgentDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let overview: AgentOverview
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var inspector: AgentInspectorModel
    let reference: AgentInspectorAgent
    @State private var confirmsDelete = false
    private var context: AgentInspectorContext { .agent(reference) }
    private var instructionExpanded: Bool {
        inspector.presentation[context]?.expandedInstructions ?? false
    }
    private var configurationExpanded: Binding<Bool> {
        Binding(get: { inspector.presentation[context]?.expandedDetails ?? false },
                set: { inspector.presentation[context, default: AgentInspectorPresentation()].expandedDetails = $0 })
    }
    private var scrollAnchor: Binding<String?> {
        Binding(get: { inspector.presentation[context]?.scrollAnchor },
                set: { inspector.presentation[context, default: AgentInspectorPresentation()].scrollAnchor = $0 })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Button { inspector.back() } label: {
                    Label("All agents", systemImage: "chevron.left")
                }
                .buttonStyle(.locus())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agentOverview.back")
                identityCard.id("identity")
                AgentInspectorLoadStatus(inspector: inspector)
                if let error = overview.lastError {
                    attentionBanner(error)
                }
                workingCard.id("working")
                statsStrip.id("stats")
                eventsCard.id("events")
                chatsCard.id("chats")
                VStack(spacing: 10) {
                    Button {
                        configurationExpanded.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: configurationExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .font(.locus(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text("How it works")
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 13, weight: .semibold))
                    .accessibilityLabel("How it works")
                    .accessibilityValue(configurationExpanded.wrappedValue ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows or hides the agent's source and instructions")
                    .accessibilityIdentifier("agentOverview.configuration")
                    if configurationExpanded.wrappedValue {
                        triggerCard
                        behaviorCard
                    }
                }
                .accessibilityElement(children: .contain)
                .id("configuration")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: instructionExpanded)
        .alert("Delete \(overview.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let definition = overview.definition { model.deleteAgent(definition) }
            }
        } message: {
            Text("Its chats and \(overview.vocabulary.arrival) history are kept;"
                + " only the \(overview.vocabulary.record) is removed.")
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                AgentGlyph(size: 40, symbolSize: 20, status: overview.status)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(overview.name)
                            .font(.locus(size: 13, weight: .bold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(2)
                            .accessibilityIdentifier("agentOverview.name")
                        Spacer(minLength: 4)
                        AgentStatusPill(status: overview.status, vocabulary: overview.vocabulary)
                            .accessibilityIdentifier("agentOverview.status")
                    }
                    Text(overview.purpose)
                        .font(.locus(size: 13))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(3)
                        .accessibilityIdentifier("agentOverview.summary")
                }
            }

            AgentFlowLayout(spacing: 6) {
                if overview.definition != nil {
                    AgentActionButton(
                        title: "New chat",
                        symbol: "plus",
                        prominent: true,
                        help: "Start a side conversation with this agent."
                            + " It does not receive \(overview.vocabulary.arrivals).",
                        identifier: "agentOverview.newChat"
                    ) {
                        model.newAgentChat(reference: reference)
                    }
                }
                if let definition = overview.definition {
                    if overview.canRunNow {
                        AgentActionButton(
                            title: "Run now",
                            symbol: "play.circle",
                            help: "Run this schedule immediately in its chat",
                            identifier: "agentOverview.runNow"
                        ) {
                            model.runAgentNow(definition)
                        }
                    }
                    AgentActionButton(
                        title: "Edit",
                        symbol: "slider.horizontal.3",
                        help: "Change what starts this agent and what it does",
                        identifier: "agentOverview.edit"
                    ) {
                        model.editAgent(definition)
                    }
                    AgentActionButton(
                        title: definition.enabled ? "Pause" : "Resume",
                        symbol: definition.enabled ? "pause" : "play",
                        prominent: overview.status.needsResume,
                        help: definition.isSchedule
                            ? (definition.enabled
                                ? "Skip scheduled runs until you resume it"
                                : "Run on schedule again")
                            : (definition.enabled
                                ? "Keep recording events without starting chats"
                                : "Start chats for matching events again"),
                        identifier: "agentOverview.toggle"
                    ) {
                        model.setAgentEnabled(definition, enabled: !definition.enabled)
                    }
                    .disabled(model.isChangingAgentEnabled(definition))
                    if overview.canRearm, let trigger = overview.trigger {
                        AgentActionButton(
                            title: "Re-arm",
                            symbol: "arrow.counterclockwise",
                            help: "Watch for the price condition again",
                            identifier: "agentOverview.rearm"
                        ) {
                            automation.rearm(trigger)
                        }
                    }
                }
                moreMenu
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(overview.name), \(overview.status.title(for: overview.vocabulary))"
        )
        .accessibilityIdentifier("agentOverview.identity")
    }

    private var moreMenu: some View {
        Menu {
            if let trigger = overview.trigger {
                Button("Run History…") {
                    model.presentConfigureAgent(focusing: trigger, tab: .runHistory)
                }
                .accessibilityIdentifier("agentOverview.menu.runHistory")
            }
            Button("Manage Agents…") {
                model.presentConfigureAgent(draftText: "")
            }
            .accessibilityIdentifier("agentOverview.menu.manage")
            Button("New Agent…") { model.presentNewAgent() }
                .accessibilityIdentifier("agentOverview.menu.newAgent")
            if let definition = overview.definition,
               definition.lastError?.nilIfEmpty != nil {
                Button(model.isClearingAgentWarning(definition)
                    ? "Clearing Warning…" : "Clear Warning") {
                    model.clearAgentWarning(definition)
                }
                .disabled(model.isClearingAgentWarning(definition))
                .accessibilityIdentifier("agentOverview.menu.clearWarning")
            }
            if let path = overview.chats.compactMap(\.session.workspacePath).first {
                Button("Reveal Workspace in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if overview.definition != nil {
                Divider()
                Button("Delete Agent…", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("agentOverview.menu.delete")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(LocusTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(LocusTheme.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help("More")
        .accessibilityLabel("More agent actions")
        .accessibilityIdentifier("agentOverview.more")
    }

    // MARK: Attention

    private func attentionBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(LocusTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.status.isWarning
                    ? overview.status.detail(for: overview.vocabulary)
                    : "Last error")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error)
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let definition = overview.definition {
                    Button("Review agent settings") { model.editAgent(definition) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.attention.settings")
                    if definition.lastError?.nilIfEmpty != nil {
                        Button(model.isClearingAgentWarning(definition) ? "Clearing warning…" : "Clear warning") {
                            model.clearAgentWarning(definition)
                        }
                        .disabled(model.isClearingAgentWarning(definition))
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.attention.clear")
                    }
                }
                if overview.hasLostEventChat {
                    Text("Its chat cannot be restored. Delete this agent and configure a new one.")
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.attention")
    }

    // MARK: Stats

    @ViewBuilder
    private var workingCard: some View {
        let working = overview.chats.filter(\.isRunning)
        if !working.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                AgentEyebrow(title: "Working on")
                ForEach(working) { chat in
                    Button(chat.session.displayTitle) {
                        inspector.show(.chat(reference, sessionID: chat.id))
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 12, weight: .medium))
                    .accessibilityIdentifier("agentOverview.working.\(chat.id)")
                }
            }.agentCard()
        } else if let task = overview.schedule, task.enabled, let next = task.nextRunDate {
            VStack(alignment: .leading, spacing: 6) {
                AgentEyebrow(title: "Up next")
                Text(AgentOverviewFormatting.absolute(next))
                    .font(.locus(size: 12, weight: .medium))
                Text(AgentOverviewFormatting.rule(task.rule))
                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
            }.agentCard()
        }
    }

    private var statsStrip: some View {
        VStack(alignment: .leading, spacing: 16) {
            activityFact(
                overview.chats.count == 1 ? "Chat" : "Chats",
                value: "\(overview.chats.count)",
                detail: overview.runningChatCount > 0 ? "\(overview.runningChatCount) working now" : "No chats are running",
                identifier: "agentOverview.stats.chats"
            )
            activityFact(
                overview.schedule != nil ? "Runs" : "Events",
                value: "\(inspector.snapshot.history?.total ?? overview.eventCount)",
                detail: inspector.snapshot.history.map {
                    "Across saved history: \($0.completedCount) completed, \($0.activeCount) in progress, \($0.attentionCount) need attention."
                } ?? "Recent loaded history only.",
                identifier: "agentOverview.stats.events"
            )
            activityFact(
                overview.schedule != nil ? "Last run" : "Last event",
                value: overview.lastEventAt.map { AgentOverviewFormatting.relative($0) } ?? "None yet",
                detail: overview.lastEventAt.map { $0.formatted(date: .abbreviated, time: .shortened) },
                identifier: "agentOverview.stats.lastEvent"
            )
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.stats")
    }

    private func activityFact(_ title: String, value: String, detail: String?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.locus(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(value).font(.locus(size: 13, weight: .semibold))
            }
            if let detail {
                Text(detail).font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value). \(detail ?? "")")
        .accessibilityIdentifier(identifier)
    }

    // MARK: Trigger

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentEyebrow(title: "What starts it")
            if let task = overview.schedule {
                HStack(spacing: 9) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .frame(width: 28, height: 28)
                        .background(LocusTheme.signal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AgentOverviewFormatting.rule(task.rule))
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        Text(task.nextRunDate.map {
                            "Next run \(AgentOverviewFormatting.absolute($0))"
                        } ?? (task.enabled ? "No next run" : "Paused"))
                            .font(.locus(size: 12))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agentOverview.source")
                if !overview.filters.isEmpty {
                    AgentChipFlow(chips: overview.filters)
                        .accessibilityIdentifier("agentOverview.filters")
                }
            } else if let trigger = overview.trigger {
                HStack(spacing: 9) {
                    Image(systemName: overview.connection?.kind.symbol
                        ?? (trigger.triggerKind == .price ? "chart.line.uptrend.xyaxis" : "bolt"))
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(overview.connection == nil ? LocusTheme.warning : LocusTheme.signalDeep)
                        .frame(width: 28, height: 28)
                        .background((overview.connection == nil ? LocusTheme.warning : LocusTheme.signal).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overview.connection?.displayName.nilIfEmpty ?? "Missing connection")
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        Text(triggerSourceDetail(trigger))
                            .font(.locus(size: 12))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agentOverview.source")

                AgentChipFlow(chips: overview.filters)
                    .accessibilityIdentifier("agentOverview.filters")

                if let priceState = overview.priceState {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.locus(size: 12, weight: .semibold))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .accessibilityHidden(true)
                        Text(priceState)
                            .font(.locus(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .lineLimit(2)
                    }
                    .accessibilityIdentifier("agentOverview.priceState")
                }
            } else {
                Text(overview.status.detail(for: overview.vocabulary))
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What starts it")
        .accessibilityIdentifier("agentOverview.trigger")
    }

    private func triggerSourceDetail(_ trigger: EventTrigger) -> String {
        var parts = [overview.connection?.kind.title ?? trigger.triggerKind.title]
        if let connection = overview.connection {
            let health = connection.health.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(connection.enabled ? health.capitalized : "Disabled")
            if let polled = connection.lastPolledAt {
                parts.append("checked \(AgentOverviewFormatting.relative(Date(timeIntervalSince1970: polled)))")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Behavior

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentEyebrow(title: "What it does")
            if overview.instruction.isEmpty {
                Text(overview.definition == nil
                    ? "No instruction is stored without a trigger."
                    : "No instruction yet — the agent receives each event as is.")
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(overview.instruction)
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.ink)
                        .lineSpacing(2)
                        .lineLimit(instructionExpanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agentOverview.instruction")
                    if overview.instruction.count > 220 || overview.instruction.contains("\n") {
                        Button(instructionExpanded ? "Show less" : "Show more") {
                            inspector.presentation[context, default: AgentInspectorPresentation()].expandedInstructions.toggle()
                        }
                        .buttonStyle(.locus())
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("agentOverview.instruction.toggle")
                    }
                }
            }
            if !overview.facts.isEmpty {
                Rectangle().fill(LocusTheme.line).frame(height: 1).accessibilityHidden(true)
                VStack(spacing: 7) {
                    ForEach(overview.facts) { fact in
                        AgentFactRow(fact: fact)
                    }
                }
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What it does")
        .accessibilityIdentifier("agentOverview.behavior")
    }

    // MARK: Chats

    private var chatsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentEyebrow(title: "Chats", count: overview.chats.count)
                Spacer(minLength: 4)
                if overview.definition != nil {
                    Button {
                        model.newAgentChat(reference: reference)
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.locus(size: 12, weight: .semibold))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .help("Start a side conversation with this agent."
                        + " It does not receive \(overview.vocabulary.arrivals)")
                    .accessibilityLabel("New chat with \(overview.name)")
                    .accessibilityIdentifier("agentOverview.chats.new")
                }
            }
            if let eventChat = overview.eventChat, overview.chats.count > 1 {
                Text("\(overview.vocabulary.arrivals.capitalized) arrive in"
                    + " \(eventChat.session.displayTitle). Other chats are side conversations.")
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agentOverview.chats.explainer")
            }
            if overview.chats.isEmpty {
                Text(overview.definition == nil
                    ? "No chats survived for this agent."
                    : "No chats yet. Every \(overview.vocabulary.arrival) arrives in this agent's"
                        + " \(overview.vocabulary.arrival) chat; New chat starts a side conversation"
                        + " that does not receive \(overview.vocabulary.arrivals).")
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(overview.chats) { chat in
                        AgentChatRow(chat: chat, vocabulary: overview.vocabulary) {
                            inspector.show(.chat(reference, sessionID: chat.id))
                        }
                    }
                }
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats")
        .accessibilityIdentifier("agentOverview.chats")
    }

    // MARK: Events

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentEyebrow(
                    title: overview.schedule != nil ? "Runs" : "Events",
                    count: inspector.snapshot.history?.total ?? overview.eventCount
                )
                Spacer(minLength: 4)
            }
            if historyEvents.isEmpty {
                Text(overview.schedule != nil
                    ? "No runs yet. Each run continues this agent's chat and appears here with its outcome."
                    : (overview.definition?.enabled == false
                        ? "Paused agents keep recording events; none have arrived yet."
                        : "Nothing has reached this agent yet. Matching events will appear here with their outcome."))
                    .font(.locus(size: 12))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(historyEvents) { event in
                        AgentEventRow(
                            event: event,
                            retrying: automation.retryingDeliveryIDs.contains(event.id),
                            allowsRetry: inspector.snapshot.history?.workflowExecutionIDs?[event.id] == nil
                                && overview.trigger?.workflowPersisted != true,
                            onRetry: { if let delivery = event.delivery { automation.retry(delivery) } },
                            onOpenChat: nil,
                            onInspect: {
                                inspector.show(reference.kind == .event
                                    ? .event(reference, deliveryID: event.id)
                                    : .occurrence(reference, occurrenceID: event.id))
                            }
                        )
                    }
                    if inspector.snapshot.history?.nextCursor != nil {
                        Button(inspector.isLoading ? "Loading…" : "Load more") {
                            Task { await inspector.refresh(backend: model.backend, append: true) }
                        }
                        .disabled(inspector.isLoading)
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.events.loadMore")
                    }
                }
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent \(overview.vocabulary.arrivals)")
        .accessibilityIdentifier("agentOverview.events")
    }

    private var historyEvents: [AgentOverview.Event] {
        guard let history = inspector.snapshot.history else { return overview.events }
        return reference.kind == .event
            ? (history.deliveries ?? []).map(AgentOverview.Event.init(delivery:))
            : (history.occurrences ?? []).map(AgentOverview.Event.init(occurrence:))
    }

    private func openChat(for event: AgentOverview.Event) -> (() -> Void)? {
        guard let sessionID = event.sessionID,
              let session = model.sessionCatalog.snapshot.sessionsByID[sessionID]
        else { return nil }
        return {
            guard session.id != model.currentSessionID else { return }
            model.resume(session)
        }
    }
}

// MARK: - Fleet

private struct AgentFleetView: View {
    @EnvironmentObject private var model: AppModel
    let entries: [AgentFleetEntry]
    @ObservedObject var automation: EventAutomationModel

    private var activeCount: Int { entries.filter { $0.status == .active }.count }
    private var stoppedCount: Int { entries.filter { $0.status.needsResume }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if let error = automation.lastError, !error.isEmpty, entries.isEmpty {
                    Text(error)
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .agentCard()
                }
                if entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(entries, id: \.inspectorID) { entry in
                            AgentFleetRow(entry: entry) { open(entry) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("agentOverview.fleet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                AgentGlyph(size: 40, symbolSize: 20, status: .active)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents")
                        .font(.locus(size: 13, weight: .bold))
                        .foregroundStyle(LocusTheme.ink)
                    Text(fleetSummary)
                        .font(.locus(size: 12, weight: .medium))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("agentOverview.fleet.summary")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                AgentActionButton(
                    title: "New agent",
                    symbol: "plus",
                    prominent: true,
                    help: "Configure an agent that wakes on email, messages, webhooks, or a price",
                    identifier: "agentOverview.fleet.create"
                ) {
                    model.presentNewAgent()
                }
                AgentActionButton(
                    title: "Sources",
                    symbol: "point.3.connected.trianglepath.dotted",
                    help: "Connect Gmail, Telegram, a webhook, or a price feed",
                    identifier: "agentOverview.fleet.manage"
                ) {
                    model.presentConfigureAgent(draftText: "")
                    model.configureAgentTab = .sources
                }
                Spacer(minLength: 0)
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.fleet.header")
    }

    private var fleetSummary: String {
        guard !entries.isEmpty else { return "Persistent agents that wake on events and schedules" }
        var parts = ["\(entries.count) configured", "\(activeCount) active"]
        if stoppedCount > 0 {
            parts.append("\(stoppedCount) stopped by Locus")
        }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(locusSymbol: LocusSymbol.robot)
                .font(.locus(size: 22))
                .foregroundStyle(LocusTheme.muted)
                .accessibilityHidden(true)
            Text("No agents yet")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
            Text("An agent waits on something — Gmail, Telegram, a webhook, a price, or a schedule — and does its own work in its own chats. Configure one and it appears here.")
                .font(.locus(size: 12))
                .foregroundStyle(LocusTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .agentCard()
        .accessibilityIdentifier("agentOverview.fleet.empty")
    }

    private func open(_ entry: AgentFleetEntry) {
        model.selectAgent(AgentInspectorAgent(entry.definition))
    }
}

// MARK: - Pieces

private struct AgentGlyph: View {
    let size: CGFloat
    let symbolSize: CGFloat
    let status: AgentOverview.Status

    private var tint: Color {
        switch status {
        case .active, .fired: LocusTheme.signalDeep
        case .paused: LocusTheme.muted
        case .stopped, .failing, .missingTrigger: LocusTheme.warning
        }
    }

    var body: some View {
        Image(locusSymbol: LocusSymbol.robot)
            .font(.locus(size: symbolSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct AgentStatusPill: View {
    let status: AgentOverview.Status
    var vocabulary: Vocabulary = .events

    private var color: Color {
        switch status {
        case .active: LocusTheme.success
        case .paused: LocusTheme.muted
        case .stopped, .missingTrigger: LocusTheme.warning
        case .failing: LocusTheme.coral
        case .fired: LocusTheme.blue
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.title(for: vocabulary))
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .help(status.detail(for: vocabulary))
        // Combined rather than ignored: a combined element carries the pill's
        // text as its label on every macOS release XCUITest runs on.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.title(for: vocabulary))")
    }
}

private struct AgentActionButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let help: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.locus(size: 12, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
            .font(.locus(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? LocusTheme.paper : LocusTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(prominent ? LocusTheme.ink : LocusTheme.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.locus())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct AgentStatTile: View {
    let value: String
    let label: String
    let caption: String
    let captionColor: Color
    let identifier: String
    var compactValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.locus(size: compactValue ? 11 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 18, alignment: .leading)
            Text(label.uppercased())
                .font(.locus(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
            Text(caption)
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value), \(caption)")
        .accessibilityIdentifier(identifier)
    }
}

private struct AgentEyebrow: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        Text(count.map { "\(title.uppercased()) · \($0)" } ?? title.uppercased())
            .font(.locus(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(LocusTheme.muted)
            .lineLimit(1)
    }
}

private struct AgentFactRow: View {
    let fact: AgentOverview.Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .font(.locus(size: 12))
                .foregroundStyle(LocusTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(fact.value)
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(fact.isWarning ? LocusTheme.warning : LocusTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fact.label)
        .accessibilityValue(fact.value)
        .accessibilityIdentifier("agentOverview.fact.\(fact.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct AgentChatRow: View {
    let chat: AgentOverview.Chat
    var vocabulary: Vocabulary = .events
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(chat.isRunning ? LocusTheme.success : LocusTheme.line)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(chat.session.displayTitle)
                            .font(.locus(size: 10, weight: chat.isCurrent ? .semibold : .medium))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        if chat.isEventTarget {
                            Text(vocabulary.badge)
                                .font(.locus(size: 10, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(LocusTheme.signalDeep)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(LocusTheme.signal.opacity(0.16))
                                .clipShape(Capsule())
                                .accessibilityHidden(true)
                        }
                    }
                    HStack(spacing: 4) {
                        if chat.isRunning {
                            if let startedAt = chat.startedAt {
                                Text(startedAt, style: .timer)
                            } else {
                                Text("Running")
                            }
                        } else {
                            Text(AgentOverviewFormatting.relative(chat.session.date))
                        }
                        if chat.isCurrent {
                            Text("· Open now")
                        }
                    }
                    .lineLimit(1)
                    .font(.locus(size: 12))
                    .foregroundStyle(chat.isRunning ? LocusTheme.success : LocusTheme.textSecondary)
                }
                Spacer(minLength: 4)
                if !chat.isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(chat.isCurrent ? LocusTheme.signal.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.locus())
        .help(chat.isEventTarget
            ? "Every \(vocabulary.arrival) this agent receives arrives here"
            : (chat.isCurrent ? "This chat is open" : "Open \(chat.session.displayTitle)"))
        .accessibilityLabel(chat.isEventTarget
            ? "\(chat.session.displayTitle), receives \(vocabulary.arrivals)"
            : chat.session.displayTitle)
        .accessibilityValue(chat.isRunning ? "Running" : (chat.isCurrent ? "Open" : "Idle"))
        .accessibilityIdentifier("agentOverview.chat.\(chat.session.id)")
    }
}

private struct AgentEventRow: View {
    let event: AgentOverview.Event
    let retrying: Bool
    var allowsRetry = true
    let onRetry: () -> Void
    let onOpenChat: (() -> Void)?
    var onInspect: (() -> Void)? = nil

    private var stateColor: Color {
        if event.isFailed { return LocusTheme.warning }
        if event.isInFlight { return LocusTheme.blue }
        // A skipped slot neither succeeded nor failed, so it is neither green
        // nor amber: it simply passed.
        if event.isSkipped { return LocusTheme.muted }
        return LocusTheme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: event.sourceSymbol)
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(event.title)
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(stateColor).frame(width: 5, height: 5)
                    Text(event.stateTitle)
                        .font(.locus(size: 10, weight: .bold))
                        .foregroundStyle(stateColor)
                }
                .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Text(AgentOverviewFormatting.relative(event.receivedAt))
                if let price = event.observedPrice {
                    Text("· \(price)")
                        .font(.locus(size: 12, weight: .semibold, design: .monospaced))
                }
                if event.attempt > 1 {
                    Text("· attempt \(event.attempt)")
                }
                if event.matchedTriggerCount > 1 {
                    Text("· matched \(event.matchedTriggerCount) agents")
                        .foregroundStyle(LocusTheme.signalDeep)
                }
                Spacer(minLength: 0)
                if let onInspect {
                    Button("Details", action: onInspect)
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.event.\(event.id).details")
                }
                if event.canRetry && allowsRetry {
                    Button(retrying ? "Retrying…" : "Retry", action: onRetry)
                        .disabled(retrying)
                        .buttonStyle(.locus())
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("agentOverview.event.\(event.id).retry")
                }
                if let onOpenChat {
                    Button("Open chat", action: onOpenChat)
                        .buttonStyle(.locus())
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("agentOverview.event.\(event.id).open")
                }
            }
            .font(.locus(size: 12))
            .foregroundStyle(LocusTheme.textSecondary)
            .padding(.leading, 21)
            if let error = event.error?.nilIfEmpty {
                Text(error)
                    .font(.locus(size: 12))
                    .foregroundStyle(event.isSkipped ? LocusTheme.textSecondary : LocusTheme.warning)
                    .lineLimit(2)
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.paperDeep.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.title), \(event.stateTitle)")
        .accessibilityIdentifier("agentOverview.event.\(event.id)")
    }
}

private struct AgentFleetRow: View {
    let entry: AgentFleetEntry
    let action: () -> Void

    private var detail: String {
        let words = entry.definition.vocabulary
        var parts = [AgentOverviewFormatting.chatCount(entry.chatCount)]
        if entry.runningChatCount > 0 { parts.append("\(entry.runningChatCount) running") }
        if let last = entry.lastEventAt {
            parts.append("last \(words.arrival) \(AgentOverviewFormatting.relative(last))")
        } else {
            parts.append("no \(words.arrivals) yet")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(size: 30, symbolSize: 14, status: entry.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.locus(size: 12))
                        .foregroundStyle(entry.runningChatCount > 0 ? LocusTheme.success : LocusTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                AgentStatusPill(status: entry.status, vocabulary: entry.definition.vocabulary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus(.card))
        .help("View all information for \(entry.name)")
        .accessibilityLabel(
            "\(entry.name), \(entry.status.title(for: entry.definition.vocabulary)), \(detail)"
        )
        .accessibilityIdentifier("agentOverview.fleet.\(entry.id)")
    }
}

/// Filter chips wrap like tags rather than truncating into one line.
private struct AgentChipFlow: View {
    let chips: [String]

    var body: some View {
        AgentFlowLayout(spacing: 5) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.locus(size: 12, weight: .medium))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(LocusTheme.paperDeep)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(LocusTheme.line, lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filters")
        .accessibilityValue(chips.joined(separator: ", "))
    }
}

private struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews: subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews: subviews, width: bounds.width)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight), origins)
    }
}

private struct AgentCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
    }
}

private extension View {
    /// The Overview's card chrome, so the Agent tab reads as its sibling.
    func agentCard() -> some View {
        modifier(AgentCardModifier())
    }
}
