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

    var body: some View {
        Group {
            switch inspector.context {
            case .fleet:
                AgentFleetView(entries: fleet, automation: automation, schedule: schedule)
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
    @State private var showOnlyAttention = false
    @State private var showAllChats = false
    private var context: AgentInspectorContext { .agent(reference) }
    private var sourceNeedsAttention: Bool {
        AgentInspectorCopy.sourceNeedsAttention(definition: overview.definition, connection: overview.connection)
    }
    private var displayStatusTitle: String {
        AgentInspectorCopy.agentStatusTitle(overview.status, vocabulary: overview.vocabulary,
                                           isRunning: overview.runningChatCount > 0,
                                           sourceNeedsAttention: sourceNeedsAttention)
    }
    private var sourceIssue: String? {
        guard sourceNeedsAttention else { return nil }
        guard let connection = overview.connection else { return "This trigger’s connection is unavailable. Choose a connection before this agent can receive events." }
        if !connection.enabled { return "This trigger’s connection is paused. Enable it to receive new events." }
        let health = connection.health.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ").lowercased().nilIfEmpty ?? "not connected"
        return connection.lastError?.nilIfEmpty ?? "The connection is \(health). Review it before this agent can receive events."
    }
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
            LazyVStack(spacing: 4) {
                Button { inspector.back() } label: {
                    Label("All agents", systemImage: "chevron.left")
                }
                .buttonStyle(.locus())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agentOverview.back")
                identityCard.id("identity")
                AgentInspectorLoadStatus(inspector: inspector)
                if let error = overview.lastError ?? sourceIssue {
                    attentionBanner(error)
                }
                workingCard.id("working")
                triggerCard.id("trigger")
                accessAndEnvironment.id("access")
                VStack(spacing: 10) {
                    Button {
                        configurationExpanded.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: configurationExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .font(.locus(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text("Instructions & setup")
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 13, weight: .semibold))
                    .accessibilityLabel("Instructions and setup")
                    .accessibilityValue(configurationExpanded.wrappedValue ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows or hides the full instructions and advanced setup")
                    .accessibilityIdentifier("agentOverview.configuration")
                    if configurationExpanded.wrappedValue {
                        behaviorCard
                    }
                }
                .accessibilityElement(children: .contain)
                .id("configuration")
                statsStrip.id("stats")
                eventsCard.id("events")
                chatsCard.id("chats")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: instructionExpanded)
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: configurationExpanded.wrappedValue)
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: showAllChats)
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
                            .font(.locus(size: 17, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(overview.name)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("agentOverview.name")
                        Spacer(minLength: 4)
                        AgentStatusPill(status: overview.status, vocabulary: overview.vocabulary,
                                        isRunning: overview.runningChatCount > 0, sourceNeedsAttention: sourceNeedsAttention)
                            .accessibilityIdentifier("agentOverview.status")
                    }
                    .accessibilityElement(children: .contain)
                    Text(overview.summary)
                        .font(.locus(size: 11, weight: .medium))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(overview.summary)
                    Text(overview.purpose)
                        .font(.locus(size: 13))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(3)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(overview.purpose)
                        .accessibilityIdentifier("agentOverview.summary")
                }
                .accessibilityElement(children: .contain)
            }
            .accessibilityElement(children: .contain)

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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(overview.name), \(displayStatusTitle)")
        .accessibilityIdentifier("agentOverview.identity")
    }

    private var moreMenu: some View {
        Menu {
            if let trigger = overview.trigger {
                Button("Activity…") {
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
                .frame(width: 30, height: 30)
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
        .frame(width: 30, height: 30)
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
                Text(sourceNeedsAttention ? "Connection needs attention" : overview.status.isWarning
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
                if sourceNeedsAttention, let trigger = overview.trigger {
                    Button("Review connection") { model.presentConfigureAgent(focusing: trigger, tab: .sources) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.attention.connection")
                }
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
                AgentEyebrow(title: "Running now")
                ForEach(working) { chat in
                    Button(chat.session.displayTitle) {
                        inspector.show(.chat(reference, sessionID: chat.id))
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 12, weight: .medium))
                    .accessibilityIdentifier("agentOverview.working.\(chat.id)")
                }
            }.agentCard()
        }
        if overview.status != .active && overview.lastError == nil {
            Text(overview.status.detail(for: overview.vocabulary))
                .font(.locus(size: 12))
                .foregroundStyle(LocusTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }

    private var statsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentEyebrow(title: "At a glance")
            HStack(alignment: .top, spacing: 12) {
                activityFact("Chats", value: "\(overview.chats.count)",
                             identifier: "agentOverview.stats.chats")
                activityFact(overview.schedule != nil ? "Runs" : "Events",
                             value: "\(inspector.snapshot.history?.total ?? overview.eventCount)",
                             identifier: "agentOverview.stats.events")
                activityFact(overview.schedule != nil ? "Last run" : "Last event",
                             value: overview.lastEventAt.map { AgentOverviewFormatting.relative($0) } ?? "None yet",
                             identifier: "agentOverview.stats.lastEvent")
            }
            if let history = inspector.snapshot.history {
                Text("\(history.completedCount) completed · \(history.activeCount) in progress · \(history.attentionCount) need attention")
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.stats")
    }

    private func activityFact(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.locus(size: 14, weight: .semibold)).lineLimit(2)
            Text(title).font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier(identifier)
    }

    private var accessAndEnvironment: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentEyebrow(title: "Access & environment")
            if let session = overview.eventChat?.session {
                AgentFactRow(fact: .init(label: "Environment",
                                        value: overview.schedule?.executionEnvironment.title ?? session.executionEnvironment.title))
                if let path = overview.schedule?.workspaceRoot.nilIfEmpty ?? session.workspacePath {
                    AgentFactRow(fact: .init(label: "Workspace", value: URL(fileURLWithPath: path).lastPathComponent))
                        .help(path)
                }
                Button {
                    if model.currentSessionID != session.id { model.resume(session) }
                } label: {
                    Label("Open automation chat", systemImage: "bubble.left")
                        .frame(minHeight: 28)
                }
                .buttonStyle(.locus())
                .help("Automatic work continues in this chat. Tool approval policy is shared across chats and agents.")
                .accessibilityIdentifier("agentOverview.access.openChat")
            } else if let task = overview.schedule {
                AgentFactRow(fact: .init(label: "Environment", value: task.executionEnvironment.title))
                AgentFactRow(fact: .init(label: "Workspace", value: URL(fileURLWithPath: task.workspaceRoot).lastPathComponent))
                Text("The receiving chat is unavailable. Review this agent’s settings before its next run.")
                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
            } else {
                Text("Environment information is unavailable because this agent has no receiving chat.")
                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
            }
            AgentFactRow(fact: .init(label: "Approval policy", value: model.permissionMode.title,
                                    isWarning: model.permissionMode.isRisky))
            Text(model.permissionMode.detail)
                .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Shared policy · Manage permissions…") { model.presentSettings(.permissions) }
                .buttonStyle(.locus())
                .font(.locus(size: 11))
                .frame(minHeight: 26)
                .help("This approval policy applies to chats and agents throughout Locus")
                .accessibilityIdentifier("agentOverview.access.permissions")
            if let trigger = overview.trigger {
                let names = trigger.actionConnectionIDs.map { id in
                    automation.connections.first(where: { $0.id == id })?.displayName ?? "Unavailable connection"
                }
                AgentFactRow(fact: .init(label: "Connected actions", value: names.isEmpty ? "None allowed" : names.joined(separator: ", ")))
                if !names.isEmpty {
                    Text("Only the selected connections are available for service actions.")
                        .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                }
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.access")
    }

    // MARK: Trigger

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentEyebrow(title: "Trigger")
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
                            .font(.locus(size: 12, weight: .semibold))
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
                            .font(.locus(size: 12, weight: .semibold))
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
            AgentEyebrow(title: "Instructions")
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
                    ForEach(overview.facts.filter { !["Source", "Connection", "May act through", "Environment", "Workspace", "Next run"].contains($0.label) }) { fact in
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
                    ForEach(showAllChats ? overview.chats : Array(overview.chats.prefix(5))) { chat in
                        AgentChatRow(chat: chat, vocabulary: overview.vocabulary) {
                            inspector.show(.chat(reference, sessionID: chat.id))
                        }
                    }
                }
                if overview.chats.count > 5 {
                    Button(showAllChats ? "Show recent chats" : "Show all \(overview.chats.count) chats") {
                        showAllChats.toggle()
                    }
                    .buttonStyle(.locus())
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("agentOverview.chats.showAll")
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
                    title: "Activity",
                    count: inspector.snapshot.history?.total ?? overview.eventCount
                )
                Spacer(minLength: 4)
            }
            if !historyEvents.isEmpty {
                Picker("Activity filter", selection: $showOnlyAttention) {
                    Text("All activity").tag(false)
                    Text("Needs attention").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("agentOverview.events.filter")
            }
            if inspector.isLoading && inspector.loadedAt == nil && historyEvents.isEmpty {
                ProgressView("Loading activity…").controlSize(.small)
            } else if inspector.error != nil && historyEvents.isEmpty {
                Text("Activity could not be loaded. Use Try again above to refresh it.")
                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
            } else if historyEvents.isEmpty {
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
                    if visibleHistoryEvents.isEmpty {
                        Text("No items need attention in the loaded activity.")
                            .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                    ForEach(visibleHistoryEvents) { event in
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

    private var visibleHistoryEvents: [AgentOverview.Event] {
        showOnlyAttention ? historyEvents.filter { AgentInspectorCopy.activityState($0) == .attention } : historyEvents
    }

    private var historyEvents: [AgentOverview.Event] {
        guard let history = inspector.snapshot.history else { return overview.events }
        return reference.kind == .event
            ? (history.deliveries ?? []).map(AgentOverview.Event.init(delivery:))
            : (history.occurrences ?? []).map(AgentOverview.Event.init(occurrence:))
    }


}

// MARK: - Fleet

private struct AgentFleetView: View {
    @EnvironmentObject private var model: AppModel
    let entries: [AgentFleetEntry]
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var schedule: ScheduleModel
    @State private var searchText = ""
    @State private var attentionOnly = false

    private var filteredEntries: [AgentFleetEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (!attentionOnly || needsAttention(entry)) && (query.isEmpty
                || entry.name.localizedStandardContains(query)
                || entry.summary.localizedStandardContains(query))
        }
        .enumerated()
        .sorted { lhs, rhs in
            let left = needsAttention(lhs.element), right = needsAttention(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left
        }
        .map(\.element)
    }

    private func needsAttention(_ entry: AgentFleetEntry) -> Bool {
        entry.status.isWarning || AgentInspectorCopy.sourceNeedsAttention(definition: entry.definition, connection: entry.connection)
    }

    private var activeCount: Int {
        entries.filter { $0.status == .active && $0.runningChatCount == 0 && !AgentInspectorCopy.sourceNeedsAttention(definition: $0.definition, connection: $0.connection) }.count
    }
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
                if entries.isEmpty && (!automation.hasLoaded || !schedule.hasLoaded)
                    && (automation.isRefreshing || schedule.isRefreshingSchedules) {
                    ProgressView("Loading agents…").controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if entries.isEmpty && (!automation.hasLoaded || !schedule.hasLoaded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Agents unavailable", systemImage: "wifi.exclamationmark")
                            .font(.locus(size: 13, weight: .semibold))
                        Text("The agent list could not be loaded. Retry to check your saved agents.")
                            .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                        Button("Try again") {
                            Task {
                                async let events: Void = automation.refresh()
                                async let schedules: Void = schedule.refreshScheduledTasks()
                                _ = await (events, schedules)
                            }
                        }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.fleet.retry")
                    }
                    .agentCard()
                } else if entries.isEmpty {
                    emptyState
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(LocusTheme.muted)
                        TextField("Find an agent", text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("agentOverview.fleet.search")
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.locus(.icon)).help("Clear search")
                                .accessibilityLabel("Clear agent search")
                        }
                    }
                    .padding(9)
                    .background(LocusTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    Picker("Agent filter", selection: $attentionOnly) {
                        Text("All agents").tag(false)
                        Text("Needs attention").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("agentOverview.fleet.filter")
                    LazyVStack(spacing: 3) {
                        if filteredEntries.isEmpty {
                            Text(searchText.isEmpty ? "No agents need attention." : "No agents match this search.")
                                .foregroundStyle(LocusTheme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(filteredEntries, id: \.inspectorID) { entry in
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
                    help: "Create an agent that starts on a schedule, event, or price condition",
                    identifier: "agentOverview.fleet.create"
                ) {
                    model.presentNewAgent()
                }
                AgentActionButton(
                    title: "Connections",
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
        var parts = ["\(entries.count) configured", "\(activeCount) ready"]
        let running = entries.filter { $0.runningChatCount > 0 }.count
        if running > 0 { parts.append("\(running) running") }
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
                .font(.locus(size: 13, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
            Text("An agent is a reusable assistant with instructions and a trigger. Give it a job, choose what starts it, and follow its work here.")
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
    var isRunning = false
    var sourceNeedsAttention = false

    private var title: String {
        AgentInspectorCopy.agentStatusTitle(status, vocabulary: vocabulary,
                                           isRunning: isRunning, sourceNeedsAttention: sourceNeedsAttention)
    }

    private var color: Color {
        if isRunning { return LocusTheme.signalDeep }
        if sourceNeedsAttention { return LocusTheme.warning }
        return switch status {
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
            Text(title)
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .help(sourceNeedsAttention ? "The trigger’s connection needs attention" : status.detail(for: vocabulary))
        // An explicit leaf keeps the status separate from the adjacent agent
        // name when AppKit flattens a row of static SwiftUI text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(title)")
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
            .frame(height: 30)
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
                .help(fact.value)
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
                            .font(.locus(size: 12, weight: chat.isCurrent ? .semibold : .medium))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        if chat.isEventTarget {
                            Text("Automation")
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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

    private var activityState: AgentActivityState { AgentInspectorCopy.activityState(event) }
    private var stateColor: Color { activityState.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: activityState.symbol)
                    .font(.locus(size: 13, weight: .medium))
                    .foregroundStyle(stateColor)
                    .frame(width: 16).padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if let onInspect {
                        Button(action: onInspect) {
                            Text(event.title)
                                .font(.locus(size: 12, weight: .medium))
                                .foregroundStyle(LocusTheme.ink)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.locus())
                        .help("Inspect this activity and its execution history")
                    } else {
                        Text(event.title).font(.locus(size: 12, weight: .medium)).lineLimit(2)
                    }
                    Text(event.stateTitle)
                        .font(.locus(size: 11, weight: .medium))
                        .foregroundStyle(stateColor)
                    HStack(spacing: 5) {
                        Image(systemName: event.sourceSymbol).accessibilityHidden(true)
                        Text(AgentOverviewFormatting.relative(event.receivedAt))
                            .help(AgentOverviewFormatting.absolute(event.receivedAt))
                        if event.attempt > 1 { Text("· attempt \(event.attempt)") }
                    }
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                    if let price = event.observedPrice {
                        Text(price).font(.locus(size: 11, weight: .medium, design: .monospaced))
                    }
                    if event.matchedTriggerCount > 1 {
                        Text("Matched \(event.matchedTriggerCount) agents")
                            .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                    }
                }
            }
            HStack(spacing: 12) {
                if let onInspect {
                    Button("Details", action: onInspect)
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.event.\(event.id).details")
                }
                if event.canRetry && allowsRetry {
                    Button(retrying ? "Retrying…" : "Retry", action: onRetry)
                        .disabled(retrying)
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.event.\(event.id).retry")
                }
                if let onOpenChat {
                    Button("Open chat", action: onOpenChat)
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentOverview.event.\(event.id).open")
                }
                Spacer(minLength: 0)
            }
            .font(.locus(size: 11, weight: .medium))
            .foregroundStyle(LocusTheme.signalDeep)
            .frame(minHeight: 26)
            .padding(.leading, 24)
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
        .background(activityState == .attention ? LocusTheme.warning.opacity(0.06) : LocusTheme.paper.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.title), \(event.stateTitle)")
        .accessibilityIdentifier("agentOverview.event.\(event.id)")
    }
}

private struct AgentFleetRow: View {
    let entry: AgentFleetEntry
    let action: () -> Void

    private var displayStatusTitle: String {
        AgentInspectorCopy.agentStatusTitle(entry.status, vocabulary: entry.definition.vocabulary,
                                           isRunning: entry.runningChatCount > 0,
                                           sourceNeedsAttention: AgentInspectorCopy.sourceNeedsAttention(definition: entry.definition, connection: entry.connection))
    }

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
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        AgentStatusPill(status: entry.status, vocabulary: entry.definition.vocabulary,
                                        isRunning: entry.runningChatCount > 0,
                                        sourceNeedsAttention: AgentInspectorCopy.sourceNeedsAttention(definition: entry.definition, connection: entry.connection))
                        Text(AgentOverviewFormatting.chatCount(entry.chatCount))
                            .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
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
            "\(entry.name), \(displayStatusTitle), \(detail)"
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
                    .help(chip)
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
                proposal: ProposedViewSize(
                    width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width),
                    height: nil
                )
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
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, natural.width), height: nil))
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
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
    }
}

private extension View {
    /// Quiet section boundaries keep a narrow inspector readable without
    /// nesting every piece of information in another bordered surface.
    func agentCard() -> some View {
        modifier(AgentCardModifier())
    }
}
