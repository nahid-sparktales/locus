import AppKit
import SwiftUI

/// The Agent tab. With an agent's chat selected it shows that agent — who it
/// is, what wakes it, what it may do, the chats it owns, and the events that
/// reached it — with the controls that matter day to day: a new chat, pause,
/// re-arm, edit. With no agent chat selected it shows the fleet, so Agents
/// mode always has something to say.
struct InspectorAgentTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AgentInspectorPanel(
            automation: model.eventAutomations,
            sessionCatalog: model.sessionCatalog
        )
        .environmentObject(model)
    }
}

private struct AgentInspectorPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var sessionCatalog: SessionCatalogModel

    private var currentTriggerID: String? {
        sessionCatalog.snapshot.sessionsByID[model.currentSessionID]?.agentTriggerID?.nilIfEmpty
    }

    var body: some View {
        Group {
            if let triggerID = currentTriggerID {
                AgentDetailView(overview: overview(for: triggerID), automation: automation)
                    .id(triggerID)
            } else {
                AgentFleetView(entries: fleet, automation: automation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocusTheme.paperDeep)
        .foregroundStyle(LocusTheme.ink)
        .font(.locus(size: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent overview")
        .accessibilityIdentifier("agentOverview")
        // Deliveries and trigger state change without a chat event, so the
        // panel keeps itself current while it is on screen. The poll lives as
        // long as the tab does; a chat switch asks for one extra refresh on
        // its own task, so switching never cancels a request mid-flight and
        // leaves the automation model holding "cancelled" as its last error.
        // Fixtures carry their own state and have no backend to ask.
        .task {
            guard !model.isUITesting else { return }
            await automation.refresh(announceFailure: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await automation.refresh(announceFailure: false)
            }
        }
        .onChange(of: model.currentSessionID) {
            guard !model.isUITesting else { return }
            Task { await automation.refresh(announceFailure: false) }
        }
    }

    private func overview(for triggerID: String) -> AgentOverview {
        AgentOverview.resolve(
            triggerID: triggerID,
            trigger: automation.triggers.first { $0.id == triggerID },
            connections: automation.connections,
            actionConnections: automation.connections,
            sessions: sessionCatalog.snapshot.sessions,
            deliveries: automation.deliveries,
            currentSessionID: model.currentSessionID,
            runningSessionIDs: model.runningChatSessionIDs,
            startedAt: model.runningChatStartTimes
        )
    }

    private var fleet: [AgentFleetEntry] {
        AgentFleet.entries(
            triggers: automation.triggers,
            connections: automation.connections,
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
    @State private var instructionExpanded = false
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                identityCard
                if let error = overview.lastError {
                    attentionBanner(error)
                }
                statsStrip
                triggerCard
                behaviorCard
                chatsCard
                eventsCard
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: instructionExpanded)
        .alert("Delete \(overview.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let trigger = overview.trigger { automation.deleteTrigger(trigger) }
            }
        } message: {
            Text("Its chats and delivery history are kept; only the trigger is removed.")
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
                        AgentStatusPill(status: overview.status)
                            .accessibilityIdentifier("agentOverview.status")
                    }
                    Text(overview.summary)
                        .font(.locus(size: 8, weight: .medium))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("agentOverview.summary")
                }
            }

            AgentFlowLayout(spacing: 6) {
                if overview.trigger != nil {
                    AgentActionButton(
                        title: "New chat",
                        symbol: "plus",
                        prominent: true,
                        help: "Start another chat with this agent",
                        identifier: "agentOverview.newChat"
                    ) {
                        model.newAgentChat(triggerID: overview.triggerID)
                    }
                }
                if let trigger = overview.trigger {
                    AgentActionButton(
                        title: "Edit",
                        symbol: "slider.horizontal.3",
                        help: "Change what starts this agent and what it does",
                        identifier: "agentOverview.edit"
                    ) {
                        editAgent(trigger)
                    }
                    AgentActionButton(
                        title: trigger.enabled ? "Pause" : "Resume",
                        symbol: trigger.enabled ? "pause" : "play",
                        help: trigger.enabled
                            ? "Keep recording events without starting chats"
                            : "Start chats for matching events again",
                        identifier: "agentOverview.toggle"
                    ) {
                        automation.setTrigger(trigger, enabled: !trigger.enabled)
                    }
                    if overview.canRearm {
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
        .accessibilityLabel("\(overview.name), \(overview.status.title)")
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
            if let path = overview.chats.compactMap(\.session.workspacePath).first {
                Button("Reveal Workspace in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if overview.trigger != nil {
                Divider()
                Button("Delete Agent…", role: .destructive) { confirmsDelete = true }
                    .accessibilityIdentifier("agentOverview.menu.delete")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 11, weight: .semibold))
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

    private func editAgent(_ trigger: EventTrigger) {
        let isDedicated = overview.chats.contains { $0.session.id == trigger.targetSessionID }
            || overview.currentChat != nil
        model.editAgentTrigger(trigger, isDedicatedAgent: isDedicated)
    }

    // MARK: Attention

    private func attentionBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.locus(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.status.isWarning ? overview.status.detail : "Last error")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                Text(error)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentOverview.attention")
    }

    // MARK: Stats

    private var statsStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            AgentStatTile(
                value: "\(overview.chats.count)",
                label: overview.chats.count == 1 ? "Chat" : "Chats",
                caption: overview.runningChatCount > 0
                    ? "\(overview.runningChatCount) running" : "none running",
                captionColor: overview.runningChatCount > 0 ? LocusTheme.success : LocusTheme.textSecondary,
                identifier: "agentOverview.stats.chats"
            )
            AgentStatTile(
                value: "\(overview.eventCount)",
                label: overview.eventCount == 1 ? "Event" : "Events",
                caption: overview.failedEventCount > 0
                    ? "\(overview.failedEventCount) failed" : "all delivered",
                captionColor: overview.failedEventCount > 0 ? LocusTheme.warning : LocusTheme.textSecondary,
                identifier: "agentOverview.stats.events"
            )
            AgentStatTile(
                value: overview.lastEventAt.map { AgentOverviewFormatting.relative($0) } ?? "—",
                label: "Last event",
                caption: overview.lastEventAt.map { AgentOverviewFormatting.absolute($0) }
                    ?? "nothing yet",
                captionColor: LocusTheme.textSecondary,
                identifier: "agentOverview.stats.lastEvent",
                compactValue: true
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.stats")
    }

    // MARK: Trigger

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentEyebrow(title: "What starts it")
            if let trigger = overview.trigger {
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
                            .font(.locus(size: 8))
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
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .accessibilityHidden(true)
                        Text(priceState)
                            .font(.locus(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .lineLimit(2)
                    }
                    .accessibilityIdentifier("agentOverview.priceState")
                }
            } else {
                Text(overview.status.detail)
                    .font(.locus(size: 9))
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
                Text(overview.trigger == nil
                    ? "No instruction is stored without a trigger."
                    : "No instruction yet — the agent receives each event as is.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(overview.instruction)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.ink)
                        .lineSpacing(2)
                        .lineLimit(instructionExpanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agentOverview.instruction")
                    if overview.instruction.count > 220 || overview.instruction.contains("\n") {
                        Button(instructionExpanded ? "Show less" : "Show more") {
                            instructionExpanded.toggle()
                        }
                        .buttonStyle(.locus())
                        .font(.locus(size: 8, weight: .semibold))
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
                if overview.trigger != nil {
                    Button {
                        model.newAgentChat(triggerID: overview.triggerID)
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.locus(size: 8, weight: .semibold))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .help("Start another chat with this agent")
                    .accessibilityLabel("New chat with \(overview.name)")
                    .accessibilityIdentifier("agentOverview.chats.new")
                }
            }
            if overview.chats.isEmpty {
                Text(overview.trigger == nil
                    ? "No chats survived for this agent."
                    : "No chats yet. New chat gives this agent its first conversation; matching events also start one.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(overview.chats) { chat in
                        AgentChatRow(chat: chat) {
                            guard !chat.isCurrent else { return }
                            model.resume(chat.session)
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
                AgentEyebrow(title: "Recent events", count: overview.eventCount)
                Spacer(minLength: 4)
                if overview.eventCount > overview.events.count, let trigger = overview.trigger {
                    Button("View all") {
                        model.presentConfigureAgent(focusing: trigger, tab: .runHistory)
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .accessibilityIdentifier("agentOverview.events.viewAll")
                }
            }
            if overview.events.isEmpty {
                Text(overview.trigger?.enabled == false
                    ? "Paused agents keep recording events; none have arrived yet."
                    : "Nothing has reached this agent yet. Matching events will appear here with their outcome.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(overview.events) { event in
                        AgentEventRow(
                            event: event,
                            onRetry: { automation.retry(event.delivery) },
                            onOpenChat: openChat(for: event)
                        )
                    }
                }
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent events")
        .accessibilityIdentifier("agentOverview.events")
    }

    private func openChat(for event: AgentOverview.Event) -> (() -> Void)? {
        guard let sessionID = event.delivery.sessionID,
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
    private var attentionCount: Int { entries.filter { $0.status.isWarning }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                if let error = automation.lastError, !error.isEmpty, entries.isEmpty {
                    Text(error)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .agentCard()
                }
                if entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
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
                        .font(.locus(size: 8, weight: .medium))
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
                    help: "Configure a new agent",
                    identifier: "agentOverview.fleet.create"
                ) {
                    model.presentConfigureAgent(draftText: model.draftText)
                }
                AgentActionButton(
                    title: "Manage",
                    symbol: "gearshape.2",
                    help: "Open Configure Agent",
                    identifier: "agentOverview.fleet.manage"
                ) {
                    model.presentConfigureAgent(draftText: "")
                }
                Spacer(minLength: 0)
            }
        }
        .agentCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOverview.fleet.header")
    }

    private var fleetSummary: String {
        guard !entries.isEmpty else { return "Persistent agents that wake on events" }
        var parts = ["\(entries.count) configured", "\(activeCount) active"]
        if attentionCount > 0 { parts.append("\(attentionCount) need attention") }
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
            Text("An agent is a trigger — Gmail, Telegram, a webhook, or a price — with its own instruction and its own chats. Configure one and it appears here.")
                .font(.locus(size: 9))
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
        if let latest = entry.latestChat {
            model.resume(latest)
        } else {
            // No chat yet: the editor is where the agent can be given one.
            model.presentConfigureAgent(draftText: "")
        }
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
        case .needsAttention, .missingTrigger: LocusTheme.warning
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

    private var color: Color {
        switch status {
        case .active: LocusTheme.success
        case .paused: LocusTheme.muted
        case .needsAttention, .missingTrigger: LocusTheme.warning
        case .fired: LocusTheme.blue
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.title)
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
        .help(status.detail)
        // Combined rather than ignored: a combined element carries the pill's
        // text as its label on every macOS release XCUITest runs on.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.title)")
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
                    .font(.locus(size: 8, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
            }
            .font(.locus(size: 8, weight: .semibold))
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
                .font(.locus(size: 7, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
            Text(caption)
                .font(.locus(size: 7, weight: .medium))
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
            .font(.locus(size: 7, weight: .bold))
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
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(fact.value)
                .font(.locus(size: 8, weight: .semibold))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(chat.isRunning ? LocusTheme.success : LocusTheme.line)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.session.displayTitle)
                        .font(.locus(size: 10, weight: chat.isCurrent ? .semibold : .medium))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
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
                    .font(.locus(size: 8))
                    .foregroundStyle(chat.isRunning ? LocusTheme.success : LocusTheme.textSecondary)
                }
                Spacer(minLength: 4)
                if !chat.isCurrent {
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 8, weight: .semibold))
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
        .help(chat.isCurrent ? "This chat is open" : "Open \(chat.session.displayTitle)")
        .accessibilityLabel(chat.session.displayTitle)
        .accessibilityValue(chat.isRunning ? "Running" : (chat.isCurrent ? "Open" : "Idle"))
        .accessibilityIdentifier("agentOverview.chat.\(chat.session.id)")
    }
}

private struct AgentEventRow: View {
    let event: AgentOverview.Event
    let onRetry: () -> Void
    let onOpenChat: (() -> Void)?

    private var stateColor: Color {
        if event.isFailed { return LocusTheme.warning }
        if event.isInFlight { return LocusTheme.blue }
        return LocusTheme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: event.delivery.source.symbol)
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(event.title)
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle().fill(stateColor).frame(width: 5, height: 5)
                    Text(event.stateTitle)
                        .font(.locus(size: 7, weight: .bold))
                        .foregroundStyle(stateColor)
                }
                .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                Text(AgentOverviewFormatting.relative(event.receivedAt))
                if let price = event.observedPrice {
                    Text("· \(price)")
                        .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                }
                if event.delivery.attempt > 1 {
                    Text("· attempt \(event.delivery.attempt)")
                }
                Spacer(minLength: 0)
                if event.canRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.locus())
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("agentOverview.event.\(event.id).retry")
                }
                if let onOpenChat {
                    Button("Open chat", action: onOpenChat)
                        .buttonStyle(.locus())
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("agentOverview.event.\(event.id).open")
                }
            }
            .font(.locus(size: 8))
            .foregroundStyle(LocusTheme.textSecondary)
            .padding(.leading, 21)
            if let error = event.delivery.error?.nilIfEmpty {
                Text(error)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.warning)
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
        var parts = [AgentOverviewFormatting.chatCount(entry.chatCount)]
        if entry.runningChatCount > 0 { parts.append("\(entry.runningChatCount) running") }
        if let last = entry.lastEventAt {
            parts.append("last event \(AgentOverviewFormatting.relative(last))")
        } else {
            parts.append("no events yet")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(size: 30, symbolSize: 14, status: entry.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.trigger.name)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.locus(size: 8))
                        .foregroundStyle(entry.runningChatCount > 0 ? LocusTheme.success : LocusTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                AgentStatusPill(status: entry.status)
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
        .help(entry.latestChat == nil ? "Open Configure Agent" : "Open the latest chat with \(entry.trigger.name)")
        .accessibilityLabel("\(entry.trigger.name), \(entry.status.title), \(detail)")
        .accessibilityIdentifier("agentOverview.fleet.\(entry.trigger.id)")
    }
}

/// Filter chips wrap like tags rather than truncating into one line.
private struct AgentChipFlow: View {
    let chips: [String]

    var body: some View {
        AgentFlowLayout(spacing: 5) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.locus(size: 8, weight: .medium))
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
