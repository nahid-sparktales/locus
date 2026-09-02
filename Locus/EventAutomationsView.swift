import AppKit
import SwiftUI

struct ConfigureAgentView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var schedule: ScheduleModel
    @State private var connectionSheet: ConnectorKind?
    @State private var selection: AgentConfigurationReference?
    @State private var pendingConnectionRemoval: ConnectorConnection?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Group {
                switch app.configureAgentTab {
                case .configurations: configurationsTab
                case .sources: sourcesTab
                case .runHistory: runHistoryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 620, idealHeight: 720)
        .background(LocusTheme.panel)
        .animation(reduceMotion ? nil : LocusMotion.content, value: app.configureAgentTab)
        .accessibilityIdentifier("configureAgent.sheet")
        .accessibilityElement(children: .contain)
        .sheet(item: $connectionSheet) { kind in
            ConnectorSetupView(kind: kind, automation: automation)
        }
        .sheet(isPresented: Binding(
            get: { schedule.scheduleEditorDraft != nil },
            set: { if !$0 { schedule.scheduleEditorDraft = nil } }
        )) {
            if let draft = schedule.scheduleEditorDraft {
                ScheduleEditorView(draft: draft)
                    .environmentObject(app)
            }
        }
        .sheet(item: $automation.editorDraft) { draft in
            EventTriggerEditorView(
                draft: draft,
                automation: automation,
                sessions: sessionCatalog.snapshot.sessions,
                currentModel: app.agentRouteModel
            )
        }
        .sheet(item: $automation.webhookSetup) { setup in
            WebhookSecretView(setup: setup)
        }
        .alert(
            "Remove \(pendingConnectionRemoval?.displayName ?? "source")?",
            isPresented: Binding(
                get: { pendingConnectionRemoval != nil },
                set: { if !$0 { pendingConnectionRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingConnectionRemoval = nil }
            Button("Remove", role: .destructive) {
                if let connection = pendingConnectionRemoval {
                    automation.deleteConnection(connection)
                }
                pendingConnectionRemoval = nil
            }
        } message: {
            Text("Its Keychain credentials and local settings will be removed. Delivery history is kept.")
        }
        .task {
            await refresh()
            normalizeSelection()
            applyRequestedFocus()
        }
        .onAppear { app.mountPendingConfigureAgentEditor() }
        .onChange(of: app.configureAgentFocusConfigurationID) { applyRequestedFocus() }
        .onChange(of: app.configureAgentPendingTriggerEdit) {
            app.mountPendingConfigureAgentEditor()
        }
        .onChange(of: configurationReferences.map(\.id)) { oldValue, newValue in
            if let newID = Set(newValue).subtracting(oldValue).first,
               let reference = configurationReferences.first(where: { $0.id == newID }) {
                selection = reference
            } else {
                normalizeSelection()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "gearshape.2.fill")
                .font(.locus(size: 18, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .frame(width: 38, height: 38)
                .background(LocusTheme.signal.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Manage Agents")
                    .font(.locus(size: 17, weight: .bold))
                Text("Choose what starts the work, where it runs, and what it may do.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer(minLength: 16)
            Button {
                Task { await refresh() }
            } label: {
                if automation.isRefreshing || schedule.isRefreshingSchedules {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.locus(.icon))
            .help("Refresh configurations")
            .accessibilityLabel("Refresh configurations")
            .accessibilityIdentifier("configureAgent.refresh")
            Button("Done") { app.dismissConfigureAgent() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("configureAgent.close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .locusSurface(.toolbar)
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(ConfigureAgentTab.allCases) { tab in
                Button {
                    app.configureAgentTab = tab
                } label: {
                    Text(tab.title)
                        .font(.locus(size: 9, weight: app.configureAgentTab == tab
                            ? .bold : .semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(app.configureAgentTab == tab
                            ? LocusTheme.white : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                    .buttonStyle(.locus(.quiet))
                    .accessibilityValue(app.configureAgentTab == tab ? "Selected" : "Not selected")
                    .accessibilityIdentifier("configureAgent.tab.\(tab.rawValue)")
            }
        }
        .frame(maxWidth: 520)
        .padding(3)
        .background(LocusTheme.paperDeep.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Configure Agent section")
        .accessibilityIdentifier("configureAgent.tabs")
    }

    private var configurationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.configureAgentDraftSuggestion.isEmpty {
                    draftSuggestionBanner
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(
                        "Start something new",
                        detail: "Create a focused rule for when this agent should begin working."
                    )
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                        spacing: 12
                    ) {
                        creationCard(
                            kind: .schedule,
                            detail: "Run once or repeat on a schedule."
                        ) { app.presentScheduleEditor() }
                        creationCard(
                            kind: .event,
                            detail: "React to Gmail, Telegram, or a signed webhook."
                        ) {
                            automation.presentEditor(
                                targetSessionID: app.currentSessionID,
                                triggerKind: .event
                            )
                        }
                        creationCard(
                            kind: .price,
                            detail: "Watch a stock or crypto threshold."
                        ) {
                            automation.presentEditor(
                                targetSessionID: app.currentSessionID,
                                triggerKind: .price
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionHeading(
                            "Your configurations",
                            detail: "Schedules, incoming events, and price alerts in one place."
                        )
                        Spacer()
                        Text("\(configurationReferences.count)")
                            .font(.locus(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }

                    if let error = automation.lastError, !error.isEmpty {
                        errorBanner(error)
                    }

                    if configurationReferences.isEmpty {
                        ContentUnavailableView(
                            "No Configurations Yet",
                            systemImage: "gearshape.2",
                            description: Text("Choose a trigger above to configure your first agent.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .locusCard(radius: 12)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(schedule.scheduledTasks) { task in
                                TimeTriggerRow(
                                    task: task,
                                    selected: selection?.id == "schedule:\(task.id)",
                                    onSelect: { selectSchedule(task) },
                                    onEdit: { app.presentScheduleEditor(task: task) },
                                    onRun: { schedule.runScheduleNow(task) },
                                    onToggle: {
                                        schedule.setScheduleEnabled(task, enabled: !task.enabled)
                                    },
                                    onDelete: { schedule.deleteSchedule(task) }
                                )
                            }
                            ForEach(automation.triggers) { trigger in
                                EventTriggerRow(
                                    trigger: trigger,
                                    connection: automation.connections.first {
                                        $0.id == trigger.connectionID
                                    },
                                    targetChat: sessionCatalog.snapshot
                                        .sessionsByID[trigger.targetSessionID]?
                                        .displayTitle ?? "Missing chat",
                                    selected: selection?.id == configurationID(for: trigger),
                                    onSelect: { selectTrigger(trigger) },
                                    onEdit: {
                                        automation.presentEditor(
                                            trigger: trigger,
                                            targetSessionID: trigger.targetSessionID,
                                            isDedicatedAgent: sessionCatalog.snapshot
                                                .sessionsByID[trigger.targetSessionID]?
                                                .isAgentChat == true
                                        )
                                    },
                                    onToggle: {
                                        automation.setTrigger(trigger, enabled: !trigger.enabled)
                                    },
                                    onRearm: { automation.rearm(trigger) },
                                    onDelete: { automation.deleteTrigger(trigger) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("configureAgent.center")
    }

    private var sourcesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    sectionHeading(
                        "Connected sources",
                        detail: "Credentials stay in your Mac Keychain and are never added to chats."
                    )
                    Spacer()
                    Menu {
                        ForEach(ConnectorKind.allCases) { kind in
                            Button { connectionSheet = kind } label: {
                                Label(kind.title, systemImage: kind.symbol)
                            }
                        }
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("eventAutomations.addConnection")
                }

                if automation.connections.isEmpty {
                    ContentUnavailableView(
                        "No Sources Connected",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Connect Gmail, Telegram, a signed webhook, or a read-only price feed.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .locusCard(radius: 12)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(automation.connections) { connection in
                            sourceRow(connection)
                        }
                    }
                }

                Label(
                    "Removing a source requires confirmation. Sources in use must be detached from their configurations first.",
                    systemImage: "lock.shield"
                )
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .accessibilityIdentifier("configureAgent.sources")
    }

    private var runHistoryTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading(
                    "Run history",
                    detail: "Inspect the durable runs created by one configuration."
                )
                Spacer()
                Picker("Configuration", selection: $selection) {
                    if configurationReferences.isEmpty {
                        Text("No configurations").tag(AgentConfigurationReference?.none)
                    } else {
                        ForEach(configurationReferences) { reference in
                            Text("\(reference.kind.title) — \(reference.title)")
                                .tag(Optional(reference))
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 330)
                .accessibilityIdentifier("configureAgent.history.configuration")
            }

            Divider()

            Group {
                if let reference = selection {
                    if reference.kind == .schedule {
                        let values = schedule.occurrencesBySchedule[reference.configurationID] ?? []
                        if values.isEmpty {
                            historyEmptyState(
                                title: "No Time-Trigger Runs",
                                symbol: "clock",
                                detail: "Runs from the selected time trigger appear here."
                            )
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 9) {
                                    ForEach(values) { occurrence in
                                        ScheduleOccurrenceCard(occurrence: occurrence) {
                                            openChat(occurrence.sessionID)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else if filteredDeliveries.isEmpty {
                        historyEmptyState(
                            title: "No Triggered Runs",
                            symbol: "tray",
                            detail: "Durably recorded events for this configuration appear here."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 9) {
                                ForEach(filteredDeliveries, id: \.id) { delivery in
                                    EventDeliveryCard(
                                        delivery: delivery,
                                        onRetry: { automation.retry(delivery) },
                                        onOpen: { openChat(delivery.sessionID) }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    historyEmptyState(
                        title: "Choose a Configuration",
                        symbol: "clock.arrow.circlepath",
                        detail: "Select a configuration to see its run and delivery history."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .onChange(of: selection) { _, value in
            guard value?.kind == .schedule,
                  let task = schedule.scheduledTasks.first(where: {
                      $0.id == value?.configurationID
                  }) else { return }
            Task { await schedule.refreshOccurrences(for: task) }
        }
        .accessibilityIdentifier("configureAgent.runHistory")
    }

    private var draftSuggestionBanner: some View {
        let request = app.configureAgentDraftSuggestion
        let priceSuggestion = EventAutomationModel.suggestedPriceCondition(from: request)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.locus(size: 15, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 28, height: 28)
                    .background(LocusTheme.signal.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Turn this request into an automation")
                            .font(.locus(size: 11, weight: .bold))
                        if priceSuggestion != nil {
                            Text("PRICE SUGGESTED")
                                .font(.locus(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(LocusTheme.signalDeep)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(LocusTheme.signal.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                    Text(request)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Use for Time") { app.presentScheduleEditor(prompt: request) }
                    .accessibilityIdentifier("configureAgent.suggestion.time")
                Button("Use for Event") { useSuggestion(.event, request: request) }
                    .accessibilityIdentifier("configureAgent.suggestion.event")
                if priceSuggestion != nil {
                    Button("Use for Price") { useSuggestion(.price, request: request) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("configureAgent.suggestion.price")
                } else {
                    Button("Use for Price") { useSuggestion(.price, request: request) }
                        .accessibilityIdentifier("configureAgent.suggestion.price")
                }
                Spacer()
            }
            .font(.locus(size: 9, weight: .semibold))
        }
        .padding(14)
        .locusSurface(.floating, radius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.28))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("configureAgent.draftSuggestion")
    }

    private func creationCard(
        kind: AgentConfigurationKind,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: kind.symbol)
                        .font(.locus(size: 17, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(LocusTheme.signalDeep)
                }
                Text(kind.title)
                    .font(.locus(size: 11, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
                Text(detail)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .locusCard(radius: 12)
        }
        .buttonStyle(.locus(.card))
        .accessibilityIdentifier("configureAgent.create.\(kind.rawValue)")
    }

    private func sourceRow(_ connection: ConnectorConnection) -> some View {
        let inUse = automation.triggers.contains { trigger in
            trigger.connectionID == connection.id
                || trigger.actionConnectionIDs.contains(connection.id)
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: connection.kind.symbol)
                .font(.locus(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(connection.health == "error"
                    ? LocusTheme.warning : LocusTheme.signalDeep)
                .background(LocusTheme.paperDeep.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(connection.displayName)
                        .font(.locus(size: 11, weight: .bold))
                    Text(connection.health.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.locus(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(connection.health == "error"
                            ? LocusTheme.warning : LocusTheme.muted)
                }
                Text("\(connection.kind.title) · \(sourceSecurityDescription(connection.kind))")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                if let lastPolledAt = connection.lastPolledAt {
                    Text("Last checked \(Date(timeIntervalSince1970: lastPolledAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(.locus(size: 7, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                if let error = connection.lastError, !error.isEmpty {
                    Text(error)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.warning)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 12)
            Button("Remove", role: .destructive) {
                pendingConnectionRemoval = connection
            }
            .buttonStyle(ActivityActionButtonStyle())
            .disabled(inUse)
            .help(inUse ? "Remove configurations that use this source first" : "Remove this source")
        }
        .padding(13)
        .locusCard(radius: 11)
        .accessibilityIdentifier("configureAgent.source.\(connection.id)")
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LocusTheme.warning)
            Text(error).font(.locus(size: 8)).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await refresh() } }
                .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(10)
        .background(LocusTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.locus(size: 12, weight: .bold))
            Text(detail).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
        }
    }

    private func historyEmptyState(title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var configurationReferences: [AgentConfigurationReference] {
        schedule.scheduledTasks.map {
            AgentConfigurationReference(kind: .schedule, configurationID: $0.id, title: $0.name)
        } + automation.triggers.map {
            AgentConfigurationReference(
                kind: $0.triggerKind == .price ? .price : .event,
                configurationID: $0.id,
                title: $0.name
            )
        }
    }

    private var filteredDeliveries: [EventDelivery] {
        guard let selection, selection.kind != .schedule else { return [] }
        return automation.deliveries.filter { $0.triggerID == selection.configurationID }
    }

    private func configurationID(for trigger: EventTrigger) -> String {
        "\(trigger.triggerKind == .price ? "price" : "event"):\(trigger.id)"
    }

    private func selectSchedule(_ task: ScheduledTask) {
        selection = AgentConfigurationReference(
            kind: .schedule, configurationID: task.id, title: task.name
        )
        Task { await schedule.refreshOccurrences(for: task) }
    }

    private func selectTrigger(_ trigger: EventTrigger) {
        selection = AgentConfigurationReference(
            kind: trigger.triggerKind == .price ? .price : .event,
            configurationID: trigger.id,
            title: trigger.name
        )
    }

    private func useSuggestion(_ kind: EventTriggerKind, request: String) {
        automation.presentEditor(
            targetSessionID: app.currentSessionID,
            naturalLanguageRequest: request,
            triggerKind: kind
        )
    }

    /// Honors a deep link from elsewhere in the app (the Agent tab's Run
    /// History, for one) once the configuration it names is in the list.
    private func applyRequestedFocus() {
        guard let id = app.configureAgentFocusConfigurationID,
              let reference = configurationReferences.first(where: { $0.id == id })
        else { return }
        selection = reference
        app.configureAgentFocusConfigurationID = nil
        if reference.kind == .schedule,
           let task = schedule.scheduledTasks.first(where: { $0.id == reference.configurationID }) {
            Task { await schedule.refreshOccurrences(for: task) }
        }
    }

    private func normalizeSelection() {
        guard !configurationReferences.contains(where: { $0.id == selection?.id }) else { return }
        selection = configurationReferences.first
        if selection?.kind == .schedule,
           let task = schedule.scheduledTasks.first(where: { $0.id == selection?.configurationID }) {
            Task { await schedule.refreshOccurrences(for: task) }
        }
    }

    private func openChat(_ sessionID: String?) {
        guard let sessionID,
              let session = sessionCatalog.snapshot.sessionsByID[sessionID] else { return }
        app.dismissConfigureAgent()
        app.resume(session)
    }

    private func sourceSecurityDescription(_ kind: ConnectorKind) -> String {
        switch kind {
        case .gmail: "OAuth token in Keychain"
        case .telegram: "Bot token in Keychain"
        case .webhook: "HMAC secret in Keychain"
        case .priceFeed: "Read-only feed credentials in Keychain"
        }
    }

    @MainActor
    private func refresh() async {
        async let refreshEvents: Void = automation.refresh(announceFailure: false)
        async let refreshSchedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
        _ = await (refreshEvents, refreshSchedules)
    }
}

private struct AgentConfigurationReference: Identifiable, Hashable {
    let kind: AgentConfigurationKind
    let configurationID: String
    let title: String

    var id: String { "\(kind.rawValue):\(configurationID)" }
}

private struct TimeTriggerRow: View {
    let task: ScheduledTask
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRun: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: task.enabled ? "calendar.badge.clock" : "pause.circle")
                        .foregroundStyle(task.lastError == nil
                            ? (task.enabled ? LocusTheme.signalDeep : LocusTheme.muted)
                            : LocusTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(task.name).font(.locus(size: 10, weight: .bold))
                            Text("TIME TRIGGER")
                                .font(.locus(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Text(nextDescription)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        Text("Fresh chat · \(URL(fileURLWithPath: task.workspaceRoot).lastPathComponent)")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        Text(task.prompt).font(.locus(size: 9)).lineLimit(2)
                        if let error = task.lastError, !error.isEmpty {
                            Text(error).font(.locus(size: 8)).foregroundStyle(LocusTheme.warning)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus(.card))
            HStack(spacing: 7) {
                Button("Run Now", action: onRun)
                Button("Edit", action: onEdit)
                Button(task.enabled ? "Pause" : "Resume", action: onToggle)
                Spacer()
                Button("Delete", role: .destructive) { confirmsDelete = true }
            }
            .font(.locus(size: 8, weight: .semibold))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(11)
        .background(selected ? LocusTheme.signal.opacity(0.12) : LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? LocusTheme.signalDeep : LocusTheme.line) }
        .accessibilityIdentifier("configureAgent.timeTrigger.\(task.id)")
        .alert("Delete \(task.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: { Text("Its generated chats and run history will be kept.") }
    }

    private var nextDescription: String {
        guard let date = task.nextRunDate else { return task.enabled ? "No next run" : "Paused" }
        return "Next \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ScheduleOccurrenceCard: View {
    let occurrence: ScheduleOccurrence
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Time Trigger", systemImage: "calendar.badge.clock")
                    .font(.locus(size: 9, weight: .bold))
                Spacer()
                Text(occurrence.state.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
            }
            Text(occurrence.scheduleName).font(.locus(size: 10, weight: .semibold))
            Text(Date(timeIntervalSince1970: occurrence.scheduledFor)
                .formatted(date: .abbreviated, time: .shortened))
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            if let error = occurrence.error, !error.isEmpty {
                Text(error).font(.locus(size: 8)).foregroundStyle(LocusTheme.warning)
            }
            if occurrence.sessionID != nil {
                Button("Open Chat", action: onOpen)
                    .font(.locus(size: 8, weight: .semibold))
                    .buttonStyle(ActivityActionButtonStyle())
            }
        }
        .padding(10)
        .background(LocusTheme.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line) }
    }
}

private struct EventTriggerRow: View {
    let trigger: EventTrigger
    let connection: ConnectorConnection?
    var targetChat = "Existing chat"
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onRearm: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: trigger.enabled
                        ? (trigger.triggerKind == .price ? "chart.line.uptrend.xyaxis.circle.fill" : "bolt.circle.fill")
                        : "pause.circle")
                        .foregroundStyle(trigger.lastError == nil
                            ? (trigger.enabled ? LocusTheme.signalDeep : LocusTheme.muted)
                            : LocusTheme.warning)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(trigger.name)
                                .font(.locus(size: 10, weight: .bold))
                            Text(status.uppercased())
                                .font(.locus(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(trigger.lastError == nil
                                    ? LocusTheme.muted : LocusTheme.warning)
                        }
                        Text("\(trigger.triggerKind.title) · \(connection?.displayName ?? "Missing connection") · \(trigger.mode.title)")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        Text("Target chat · \(targetChat)")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        Text(trigger.instruction)
                            .font(.locus(size: 9))
                            .lineLimit(2)
                        if let error = trigger.lastError, !error.isEmpty {
                            Text(error)
                                .font(.locus(size: 8, weight: .semibold))
                                .foregroundStyle(LocusTheme.warning)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus(.card))
            HStack(spacing: 7) {
                Button("Edit", action: onEdit)
                if trigger.triggerKind == .price && trigger.runtimeState.fired == true {
                    Button("Re-arm", action: onRearm)
                }
                Button(trigger.enabled ? "Pause" : "Resume", action: onToggle)
                Spacer()
                Button("Delete", role: .destructive) { confirmsDelete = true }
            }
            .font(.locus(size: 8, weight: .semibold))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(11)
        .background(selected ? LocusTheme.signal.opacity(0.12) : LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? LocusTheme.signalDeep : LocusTheme.line) }
        .alert("Delete \(trigger.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Its delivery and chat run history will be kept.")
        }
    }

    private var status: String {
        if trigger.lastError != nil { return "Needs attention" }
        if trigger.triggerKind == .price && trigger.runtimeState.fired == true { return "Fired" }
        return trigger.enabled ? "Active" : "Paused"
    }
}

private struct EventDeliveryCard: View {
    let delivery: EventDelivery
    let onRetry: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(delivery.source.title, systemImage: delivery.source.symbol)
                    .font(.locus(size: 9, weight: .bold))
                Spacer()
                Text(delivery.state.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(delivery.error == nil ? LocusTheme.muted : LocusTheme.warning)
            }
            Text(delivery.event.subject.isEmpty ? delivery.event.eventType : delivery.event.subject)
                .font(.locus(size: 10, weight: .semibold))
                .lineLimit(2)
            if delivery.event.eventType == "price.quote",
               let price = delivery.event.data["price"]?.string {
                Text("Observed price: \(price)")
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
            }
            if !delivery.event.text.isEmpty {
                Text(delivery.event.text)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
            }
            Text("Untrusted event data · \(Date(timeIntervalSince1970: delivery.receivedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
            if let error = delivery.error, !error.isEmpty {
                Text(error)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.warning)
            }
            HStack {
                if ["failed", "interrupted", "cancelled"].contains(delivery.state) {
                    Button("Retry", action: onRetry)
                }
                if delivery.sessionID != nil { Button("Open Chat", action: onOpen) }
                Spacer()
            }
            .font(.locus(size: 8, weight: .semibold))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(10)
        .background(LocusTheme.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line) }
        .accessibilityIdentifier("eventDelivery.\(delivery.id)")
    }
}

private struct ConnectorSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ConnectorKind
    @ObservedObject var automation: EventAutomationModel
    @State private var displayName = ""
    @State private var token = ""
    @State private var port = Int(EventWebhookServer.defaultPort)
    @State private var allowLAN = false
    @State private var tunnelURL = ""
    @State private var endpointTemplate = ""
    @State private var priceJSONPath = ""
    @State private var timestampJSONPath = ""
    @State private var testSymbol = ""
    @State private var testDisplaySymbol = ""
    @State private var testAssetClass = "crypto"
    @State private var quoteCurrency = "USD"
    @State private var pollIntervalSeconds = 60
    @State private var maxQuoteAgeSeconds = 300
    @State private var allowLocalNetwork = false
    @State private var priceSecrets: [PriceSecretDraft] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Connect \(kind.title)", systemImage: kind.symbol)
                    .font(.locus(size: 15, weight: .bold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(actionTitle) {
                    Task {
                        switch kind {
                        case .gmail:
                            await automation.connectGmail(displayName: displayName)
                        case .telegram:
                            await automation.connectTelegram(displayName: displayName, botToken: token)
                        case .webhook:
                            await automation.createWebhook(
                                displayName: displayName, port: port,
                                allowLAN: allowLAN, tunnelURL: tunnelURL
                            )
                        case .priceFeed:
                            let fields = priceSecrets.filter { !$0.key.isEmpty }.map {
                                PriceFeedSecretField(key: $0.key, placement: $0.placement)
                            }
                            let configuration = PriceFeedConfiguration(
                                endpointTemplate: endpointTemplate,
                                priceJSONPath: priceJSONPath,
                                timestampJSONPath: timestampJSONPath,
                                pollIntervalSeconds: pollIntervalSeconds,
                                maxQuoteAgeSeconds: maxQuoteAgeSeconds,
                                allowLocalNetwork: allowLocalNetwork,
                                secretFields: fields
                            )
                            var secrets: [String: String] = [:]
                            for secret in priceSecrets where !secret.key.isEmpty && !secret.value.isEmpty {
                                secrets[secret.key] = secret.value
                            }
                            let condition = PriceCondition(
                                providerSymbol: testSymbol,
                                displaySymbol: testDisplaySymbol.nilIfBlank ?? testSymbol,
                                assetClass: testAssetClass,
                                quoteCurrency: quoteCurrency,
                                comparison: .crossesAbove,
                                threshold: "1"
                            )
                            if await automation.connectPriceFeed(
                                displayName: displayName,
                                configuration: configuration,
                                secrets: secrets,
                                testCondition: condition
                            ) { dismiss() }
                            return
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveDisabled)
            }
            Form {
                TextField("Connection name", text: $displayName)
                if kind == .gmail {
                    LabeledContent("Access") {
                        Text("Google OAuth · gmail.modify")
                    }
                    Text("The browser opens for Google sign-in. Tokens stay in your Mac Keychain and never enter a chat.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                } else if kind == .telegram {
                    SecureField("Bot token", text: $token)
                    Text("The token stays in your Mac Keychain. Use trigger filters to allow only expected chats, senders, commands, and message types.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                } else if kind == .webhook {
                    TextField("Listener port", value: $port, format: .number)
                    Toggle("Allow devices on the local network", isOn: $allowLAN)
                    TextField("Optional tunnel URL", text: $tunnelURL)
                    Text("The listener binds to localhost by default. Locus does not operate a cloud relay; configure your own tunnel if the sender is remote.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("eventAutomations.webhookSecurityNote")
                } else {
                    TextField("HTTPS GET endpoint with {symbol}", text: $endpointTemplate)
                    TextField("Price JSON path", text: $priceJSONPath)
                    TextField("Optional timestamp JSON path", text: $timestampJSONPath)
                    HStack {
                        TextField("Test provider symbol", text: $testSymbol)
                        TextField("Display symbol", text: $testDisplaySymbol)
                    }
                    Picker("Asset", selection: $testAssetClass) {
                        Text("Crypto").tag("crypto")
                        Text("Stock").tag("stock")
                    }
                    TextField("Quote currency", text: $quoteCurrency)
                    Stepper(
                        "Poll every \(pollIntervalSeconds) seconds",
                        value: $pollIntervalSeconds, in: 15...86_400, step: 15
                    )
                    Stepper(
                        "Reject quotes older than \(maxQuoteAgeSeconds) seconds",
                        value: $maxQuoteAgeSeconds, in: 30...86_400, step: 30
                    )
                    Toggle("Allow private or local-network hosts", isOn: $allowLocalNetwork)
                    ForEach($priceSecrets) { $secret in
                        HStack {
                            TextField("Header or query name", text: $secret.key)
                            Picker("Placement", selection: $secret.placement) {
                                Text("Header").tag(PriceFeedSecretField.Placement.header)
                                Text("Query").tag(PriceFeedSecretField.Placement.query)
                            }
                            SecureField("Secret value", text: $secret.value)
                            Button(role: .destructive) {
                                priceSecrets.removeAll { $0.id == secret.id }
                            } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    Button("Add protected credential") {
                        if priceSecrets.count < 4 { priceSecrets.append(PriceSecretDraft()) }
                    }
                    .disabled(priceSecrets.count >= 4)
                    Text("Test & Connect must parse a finite positive decimal. Secret values stay in Keychain; only their field names are saved.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("configureAgent.priceSourceSecurityNote")
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var actionTitle: String {
        switch kind {
        case .webhook: "Create"
        case .priceFeed: "Test & Connect"
        default: "Connect"
        }
    }

    private var saveDisabled: Bool {
        if kind == .telegram { return token.trimmingCharacters(in: .whitespaces).isEmpty }
        if kind == .priceFeed {
            let credentialKeys = priceSecrets.compactMap { secret -> String? in
                let key = secret.key.trimmingCharacters(in: .whitespacesAndNewlines)
                return key.isEmpty ? nil : key.lowercased()
            }
            let hasInvalidCredentialName = priceSecrets.contains { secret in
                let key = secret.key.trimmingCharacters(in: .whitespacesAndNewlines)
                return !key.isEmpty && key.range(
                    of: #"^[A-Za-z0-9._~-]{1,80}$"#,
                    options: .regularExpression
                ) == nil
            }
            return !endpointTemplate.contains("{symbol}")
                || priceJSONPath.trimmingCharacters(in: .whitespaces).isEmpty
                || testSymbol.trimmingCharacters(in: .whitespaces).isEmpty
                || priceSecrets.contains { $0.key.isEmpty != $0.value.isEmpty }
                || hasInvalidCredentialName
                || Set(credentialKeys).count != credentialKeys.count
        }
        return false
    }
}

private struct PriceSecretDraft: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var placement: PriceFeedSecretField.Placement = .header
    var value = ""
}

private struct EventTriggerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventTriggerEditorDraft
    @State private var connectionSheet: ConnectorKind?
    @ObservedObject var automation: EventAutomationModel
    let sessions: [SessionSummary]
    let currentModel: String

    init(
        draft: EventTriggerEditorDraft,
        automation: EventAutomationModel,
        sessions: [SessionSummary],
        currentModel: String
    ) {
        _draft = State(initialValue: draft)
        self.automation = automation
        self.sessions = sessions
        self.currentModel = currentModel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editorTitle)
                    .font(.locus(size: 15, weight: .bold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(draft.id == nil ? "Activate" : "Save") {
                    Task { if await automation.saveTrigger(draft) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(automation.isSaving || missingRequirement != nil)
                .help(missingRequirement ?? (draft.id == nil
                    ? "Start listening for these events"
                    : "Save this agent"))
                .accessibilityIdentifier("eventTrigger.save")
            }
            if let missingRequirement {
                Text(missingRequirement)
                    .font(.locus(size: 8, weight: .medium))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("eventTrigger.requirement")
            }
            Divider()
            Form {
                Section("What starts it") {
                    if draft.id == nil {
                        Picker("Configuration", selection: $draft.triggerKind) {
                            Text("Incoming Event").tag(EventTriggerKind.event)
                            Text("Price Alert").tag(EventTriggerKind.price)
                        }
                        .onChange(of: draft.triggerKind) { _, kind in
                            draft.connectionID = ""
                            draft.actionConnectionIDs = []
                            draft.filters = EventTriggerFilters()
                            if kind == .price { draft.filters.priceCondition = PriceCondition() }
                        }
                    }
                    TextField("Name", text: $draft.name)
                    Picker("Connection", selection: $draft.connectionID) {
                        Text(eligibleConnections.isEmpty
                            ? "No sources connected yet" : "Choose a connection").tag("")
                        ForEach(eligibleConnections) { connection in
                            Text(connection.displayName).tag(connection.id)
                        }
                    }
                    .onChange(of: draft.connectionID) { _, value in
                        let kind = automation.connections.first { $0.id == value }?.kind
                        if draft.triggerKind == .price {
                            draft.actionConnectionIDs = []
                            draft.filters.eventNames = kind == .webhook ? ["price.quote"] : []
                        } else if draft.actionConnectionIDs.isEmpty,
                                  kind != .webhook, kind != .priceFeed {
                            draft.actionConnectionIDs = [value]
                        }
                    }
                    Menu {
                        ForEach(addableConnectorKinds) { kind in
                            Button {
                                connectionSheet = kind
                            } label: {
                                Label(kind.title, systemImage: kind.symbol)
                            }
                            .accessibilityIdentifier("eventTrigger.addSource.\(kind.rawValue)")
                        }
                    } label: {
                        Label(
                            eligibleConnections.isEmpty ? "Connect a source…" : "Add a source…",
                            systemImage: "plus"
                        )
                        .font(.locus(size: 9, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityIdentifier("eventTrigger.addSource")
                    sourceFilters
                }
                Section("What it does") {
                    Picker("Destination", selection: $draft.targetSessionID) {
                        Text("Its own agent chat")
                            .tag(EventTriggerEditorDraft.dedicatedAgentChat)
                        Text("Choose an existing chat").tag("")
                        ForEach(sessions.filter { !$0.isArchived }) { session in
                            Text(session.displayTitle).tag(session.id)
                        }
                    }
                    if draft.targetSessionID == EventTriggerEditorDraft.dedicatedAgentChat {
                        if draft.id != nil, let model = existingAgentModel {
                            // An edit keeps the agent's own model, because it
                            // used to follow whatever the app was set to. The
                            // change is available, but it has to be asked for:
                            // it is also the way a broken route is repaired.
                            VStack(alignment: .leading, spacing: 3) {
                                Text(draft.adoptCurrentRoute
                                    ? "Moves to \(currentModel) when you save."
                                    : "Runs on \(model). Saving keeps that model.")
                                    .font(.locus(size: 8, weight: .medium))
                                    .foregroundStyle(LocusTheme.textSecondary)
                                if !draft.adoptCurrentRoute, currentModel != model {
                                    Button("Switch to \(currentModel)") {
                                        draft.adoptCurrentRoute = true
                                    }
                                    .buttonStyle(.locus())
                                    .font(.locus(size: 8, weight: .semibold))
                                    .accessibilityIdentifier("eventTrigger.route.adopt")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("eventTrigger.route")
                        } else {
                            Text("Creates one lasting conversation in Agents that every matching event arrives in. It keeps its own agent identity while retaining access to the selected chat’s workspace, so future context and AGENTS.md settings can attach to it.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(WorkMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instruction")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.textSecondary)
                        TextEditor(text: $draft.instruction)
                            .font(.locus(size: 10))
                            .frame(minHeight: 110)
                            .overlay(alignment: .topLeading) {
                                if draft.instruction.isEmpty {
                                    Text("What should this agent do with each event?")
                                        .font(.locus(size: 10))
                                        .foregroundStyle(LocusTheme.muted)
                                        .padding(.leading, 5)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Instruction")
                            .accessibilityIdentifier("eventTrigger.instruction")
                    }
                    Text("This saved instruction is trusted configuration. Incoming bodies and JSON values are untrusted data and cannot alter permissions or this trigger.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Section("Allowed actions") {
                    ForEach(automation.connections.filter {
                        $0.kind != .webhook && $0.kind != .priceFeed
                    }) { connection in
                        Toggle(connection.displayName, isOn: Binding(
                            get: { draft.actionConnectionIDs.contains(connection.id) },
                            set: { enabled in
                                if enabled { draft.actionConnectionIDs.append(connection.id) }
                                else { draft.actionConnectionIDs.removeAll { $0 == connection.id } }
                            }
                        ))
                    }
                    Text("Price sources and webhooks are ingestion-only. Other connections may be explicitly allowed; the target chat's permission mode still controls every action.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 12)
        }
        .frame(width: 680, height: 700)
        .sheet(item: $connectionSheet) { kind in
            ConnectorSetupView(kind: kind, automation: automation)
        }
        .onChange(of: automation.connections.map(\.id)) { oldValue, newValue in
            // A source connected from inside the editor is almost certainly the
            // one this agent wants, so select it rather than making the person
            // find it in the picker they just left.
            guard draft.connectionID.isEmpty,
                  let added = Set(newValue).subtracting(oldValue).first,
                  eligibleConnections.contains(where: { $0.id == added }) else { return }
            draft.connectionID = added
        }
        .accessibilityIdentifier("eventAutomations.editor")
    }

    @ViewBuilder
    private var sourceFilters: some View {
        let kind = automation.connections.first { $0.id == draft.connectionID }?.kind
        if draft.triggerKind == .price {
            let condition = Binding(
                get: { draft.filters.priceCondition ?? PriceCondition() },
                set: { draft.filters.priceCondition = $0 }
            )
            TextField("Provider symbol", text: condition.providerSymbol)
            TextField("Display symbol", text: condition.displaySymbol)
            Picker("Asset", selection: condition.assetClass) {
                Text("Crypto").tag("crypto")
                Text("Stock").tag("stock")
            }
            TextField("Quote currency", text: condition.quoteCurrency)
            Picker("Condition", selection: condition.comparison) {
                ForEach(PriceComparison.allCases) { comparison in
                    Text(comparison.title).tag(comparison)
                }
            }
            TextField("Threshold", text: condition.threshold)
                .accessibilityIdentifier("eventAutomation.price.threshold")
            Picker("After firing", selection: condition.lifecycle) {
                ForEach(PriceLifecycle.allCases) { lifecycle in
                    Text(lifecycle.title).tag(lifecycle)
                }
            }
            if condition.wrappedValue.lifecycle == .repeat {
                Stepper(
                    "Repeat at most every \(condition.wrappedValue.repeatIntervalSeconds / 60) minutes",
                    value: condition.repeatIntervalSeconds,
                    in: 900...86_400, step: 900
                )
            }
            if kind == .webhook {
                Text("Send a signed price.quote event through your own relay. TradingView cannot add Locus HMAC headers directly, so point TradingView at the relay instead.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Text(verbatim: #"{"event":"price.quote","subject":"Bitcoin price update","data":{"provider_symbol":"BTCUSDT","display_symbol":"Bitcoin","asset_class":"crypto","quote_currency":"USD","price":"100000","provider_timestamp":1700000000}}"#)
                    .font(.locus(size: 8, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else if kind == .gmail {
            CSVField("Senders", values: $draft.filters.senders)
            CSVField("Recipients", values: $draft.filters.recipients)
            CSVField("Subject contains", values: $draft.filters.subjectContains)
            CSVField("Labels", values: $draft.filters.labels)
            Picker("Attachments", selection: Binding(
                get: { draft.filters.hasAttachments.map { $0 ? "yes" : "no" } ?? "either" },
                set: { draft.filters.hasAttachments = $0 == "either" ? nil : ($0 == "yes") }
            )) {
                Text("Either").tag("either")
                Text("Has attachments").tag("yes")
                Text("No attachments").tag("no")
            }
            Text("Use any filter by itself, combine filters, or leave all blank to run for every incoming email.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
        } else if kind == .telegram {
            CSVField("Chat IDs", values: $draft.filters.chatIDs)
            CSVField("Sender IDs", values: $draft.filters.senderIDs)
            CSVField("Command prefixes", values: $draft.filters.commandPrefixes)
            CSVField("Message types", values: $draft.filters.messageTypes)
        } else if kind == .webhook {
            CSVField("Event names", values: $draft.filters.eventNames)
            ForEach($draft.filters.predicates) { $predicate in
                HStack {
                    TextField("JSON path", text: $predicate.path)
                    Picker("Condition", selection: $predicate.operation) {
                        ForEach(EventFilterPredicate.Operation.allCases) { operation in
                            Text(operation.rawValue.capitalized).tag(operation)
                        }
                    }
                    if predicate.operation != .exists {
                        TextField("Value", text: $predicate.value)
                    }
                    Button(role: .destructive) {
                        draft.filters.predicates.removeAll { $0.id == predicate.id }
                    } label: { Image(systemName: "minus.circle") }
                }
            }
            Button("Add JSON condition") {
                draft.filters.predicates.append(EventFilterPredicate())
            }
        } else {
            Text("Choose a connection to configure deterministic filters.")
                .foregroundStyle(LocusTheme.muted)
        }
    }

    /// The model recorded on the agent's own chat, when editing one.
    private var existingAgentModel: String? {
        sessions.first { $0.id == draft.templateSessionID }?.model?.nilIfEmpty
    }

    /// Which sources can start this kind of agent. Price alerts read a feed or
    /// a signed relay; everything else ingests from a messaging source.
    private var addableConnectorKinds: [ConnectorKind] {
        draft.triggerKind == .price ? [.priceFeed, .webhook] : [.gmail, .telegram, .webhook]
    }

    /// The first unmet requirement, phrased as the next thing to do. Saving
    /// used to be offered unconditionally and then fail in a toast.
    private var missingRequirement: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name this agent so you can find it later."
        }
        if draft.connectionID.isEmpty {
            return eligibleConnections.isEmpty
                ? "Connect a source first — this agent has nothing to listen to."
                : "Choose the source this agent listens to."
        }
        if draft.targetSessionID.isEmpty {
            return "Choose where this agent's events arrive."
        }
        if draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write what this agent should do with each event."
        }
        if draft.triggerKind == .price {
            guard let threshold = draft.filters.priceCondition?.thresholdDecimal,
                  threshold > 0 else {
                return "Add a positive price threshold."
            }
        }
        return nil
    }

    private var eligibleConnections: [ConnectorConnection] {
        automation.connections.filter { connection in
            guard connection.enabled else { return false }
            return draft.triggerKind == .price
                ? [.priceFeed, .webhook].contains(connection.kind)
                : connection.kind != .priceFeed
        }
    }

    private var editorTitle: String {
        if draft.id != nil { return "Edit \(draft.triggerKind.title)" }
        return "New \(draft.triggerKind.title)"
    }
}

private struct CSVField: View {
    let title: String
    @Binding var values: [String]

    init(_ title: String, values: Binding<[String]>) {
        self.title = title
        _values = values
    }

    var body: some View {
        TextField(title, text: Binding(
            get: { values.joined(separator: ", ") },
            set: { values = $0.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty } }
        ))
    }
}

private struct WebhookSecretView: View {
    @Environment(\.dismiss) private var dismiss
    let setup: WebhookSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Webhook Ready")
                .font(.locus(size: 15, weight: .bold))
            Text("Copy these now. The signing secret is stored in Keychain and will not be shown again.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            LabeledContent("Endpoint") {
                Text(setup.endpoint).font(.locus(size: 9, design: .monospaced)).textSelection(.enabled)
            }
            LabeledContent("HMAC secret") {
                Text(setup.secret).font(.locus(size: 9, design: .monospaced)).textSelection(.enabled)
            }
            Text("Sign the exact request body with HMAC-SHA256 over: timestamp + '.' + body. Send X-Locus-Event-ID, X-Locus-Timestamp, and X-Locus-Signature: v1=<hex>.")
                .font(.locus(size: 9))
            HStack {
                Button("Copy Endpoint") { copy(setup.endpoint) }
                Button("Copy Secret") { copy(setup.secret) }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
