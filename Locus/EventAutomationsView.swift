import AppKit
import SwiftUI

/// Agents own their instructions, trigger and conversations. Connections are
/// shared infrastructure; runtime limits apply across the whole application.
struct ConfigureAgentView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var schedule: ScheduleModel
    @State private var connectionSheet: ConnectorKind?
    @State private var chosenCreationKind: AgentConfigurationKind?
    @State private var selectionID: String?
    @State private var search = ""
    @State private var agentFilter = "all"
    @State private var historyAgentID = ""
    @State private var historyFilter: AgentActivityFilter = .all
    @State private var pendingConnectionRemoval: ConnectorConnection?
    @State private var pendingAgentRemoval: AgentDefinition?
    @State private var knownConfigurationIDs: Set<String>?
    @State private var isLoadingActivity = false
    @State private var initialRefreshFinished = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                navigation
                Divider()
                VStack(spacing: 0) {
                    if let error = automation.lastError ?? schedule.lastLoadError {
                        errorBanner(error).padding([.horizontal, .top], 20)
                    }
                    Group {
                        switch app.configureAgentTab {
                        case .agents: agentsTab
                        case .runHistory: runHistoryTab
                        case .sources: sourcesTab
                        case .configurations: runtimeTab
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(LocusTheme.surfaceCanvas)
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 600, idealHeight: 740)
        .background(LocusTheme.panel)
        .tint(LocusTheme.accentAction)
        .animation(reduceMotion ? nil : LocusMotion.content, value: app.configureAgentTab)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("configureAgent.sheet")
        .sheet(isPresented: $app.configureAgentCreationPresented, onDismiss: openChosenEditor) { creationSheet }
        .sheet(item: $connectionSheet) { ConnectorSetupView(kind: $0, automation: automation) }
        .sheet(isPresented: Binding(
            get: { schedule.scheduleEditorDraft != nil },
            set: { if !$0 { schedule.scheduleEditorDraft = nil } }
        )) {
            if let draft = schedule.scheduleEditorDraft {
                ScheduleEditorView(draft: draft).environmentObject(app)
            }
        }
        .sheet(item: $automation.editorDraft) { draft in
            EventTriggerEditorView(draft: draft, automation: automation,
                sessions: sessionCatalog.snapshot.sessions, currentModel: app.agentRouteModel)
        }
        .sheet(item: $automation.webhookSetup) { WebhookSecretView(setup: $0) }
        .alert("Remove \(pendingConnectionRemoval?.displayName ?? "connection")?",
            isPresented: Binding(get: { pendingConnectionRemoval != nil },
                                 set: { if !$0 { pendingConnectionRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingConnectionRemoval = nil }
            Button("Remove", role: .destructive) {
                if let connection = pendingConnectionRemoval { automation.deleteConnection(connection) }
                pendingConnectionRemoval = nil
            }
        } message: { Text("Its credentials and local settings will be removed. Activity history is kept.") }
        .alert("Delete \(pendingAgentRemoval?.name ?? "Agent")?",
            isPresented: Binding(get: { pendingAgentRemoval != nil },
                                 set: { if !$0 { pendingAgentRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingAgentRemoval = nil }
            Button("Delete Agent", role: .destructive) {
                if let definition = pendingAgentRemoval { app.deleteAgent(definition) }
                pendingAgentRemoval = nil
            }
        } message: { Text("This removes its trigger. Existing chats and activity history are kept.") }
        .task {
            await refresh()
            initialRefreshFinished = true
            knownConfigurationIDs = Set(references.map(\.id))
            normalizeSelection()
            applyRequestedFocus()
        }
        .onAppear { app.mountPendingConfigureAgentEditor() }
        .onChange(of: app.configureAgentFocusConfigurationID) { applyRequestedFocus() }
        .onChange(of: app.configureAgentPendingTriggerEdit) { app.mountPendingConfigureAgentEditor() }
        .onChange(of: app.configureAgentPendingCreation) { app.mountPendingConfigureAgentEditor() }
        .onChange(of: references.map(\.id)) { _, ids in
            defer { knownConfigurationIDs = Set(ids) }
            if let knownConfigurationIDs,
               let added = Set(ids).subtracting(knownConfigurationIDs).sorted().first {
                selectionID = added
                search = ""
                agentFilter = "all"
                app.configureAgentTab = .agents
            } else { normalizeSelection() }
        }
        .task(id: app.configureAgentTab) {
            if app.configureAgentTab == .runHistory { await refreshActivity() }
        }
        .task(id: selectionID) {
            if let task = selectedDefinition?.schedule {
                await schedule.refreshOccurrences(for: task, announceFailure: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.locus(size: 17, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .frame(width: 38, height: 38)
                .background(LocusTheme.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text("Manage Agents").font(.locus(size: 18, weight: .bold))
                Text("Create, configure and follow your Agents.")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            }
            Spacer()
            Button { Task { await refresh(); if app.configureAgentTab == .runHistory { await refreshActivity() } } } label: {
                if automation.isRefreshing || schedule.isRefreshingSchedules {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else { Image(systemName: "arrow.clockwise").frame(width: 18, height: 18) }
            }
            .buttonStyle(.locus(.icon))
            .disabled(automation.isRefreshing || schedule.isRefreshingSchedules)
            .help("Refresh Agents and activity").accessibilityLabel("Refresh Agents")
            .accessibilityIdentifier("configureAgent.refresh")
            Button("Done") { app.dismissConfigureAgent() }
                .keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                .accessibilityIdentifier("configureAgent.close")
        }
        .padding(.horizontal, 22).padding(.vertical, 17)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach([ConfigureAgentTab.agents, .runHistory, .sources, .configurations]) { tab in
                Button { app.configureAgentTab = tab } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol).frame(width: 18)
                        Text(tab.title).font(.locus(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        if tab == .agents {
                            Text("\(references.count)").font(.locus(size: 8)).monospacedDigit()
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(app.configureAgentTab == tab ? LocusTheme.signal.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(app.configureAgentTab == tab ? LocusTheme.ink : LocusTheme.inkSoft)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.locus(.quiet))
                .accessibilityAddTraits(app.configureAgentTab == tab ? .isSelected : [])
                .accessibilityValue(app.configureAgentTab == tab ? "Selected" : "Not selected")
                .accessibilityIdentifier("configureAgent.tab.\(tab.rawValue)")
            }
            Spacer()
            Divider().padding(.vertical, 8)
            Label("Runs on this Mac", systemImage: "desktopcomputer")
                .font(.locus(size: 8, weight: .medium)).foregroundStyle(LocusTheme.muted)
            Text("Keep Locus open for automatic work.")
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(width: 170)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent navigation").accessibilityIdentifier("configureAgent.tabs")
    }

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeading("Agents", detail: "An Agent is saved instructions, a trigger, and a place to work.")
                Spacer(minLength: 10)
                Button { app.configureAgentCreationPresented = true } label: {
                    Label("New Agent", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("configureAgent.newAgent")
            }.padding(20)
            if !app.configureAgentDraftSuggestion.isEmpty {
                HStack {
                    Label("Use your current request as an Agent’s instructions", systemImage: "text.bubble")
                        .font(.locus(size: 9))
                    Spacer()
                    Button("Create from request") { app.configureAgentCreationPresented = true }
                }
                .padding(12).background(LocusTheme.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .padding([.horizontal, .bottom], 20)
                .accessibilityIdentifier("configureAgent.draftSuggestion")
            }
            if !initialRefreshFinished && references.isEmpty {
                loadingState("Loading Agents…")
            } else if references.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView("Your first Agent starts here", systemImage: "sparkles",
                        description: Text("Give it instructions and choose when it should work. Each Agent keeps its own conversations and activity."))
                    Button("Create Agent") { app.configureAgentCreationPresented = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("configureAgent.empty.create")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    agentList
                    Divider()
                    if let definition = selectedDefinition {
                        agentDetail(definition)
                    } else {
                        ContentUnavailableView("Choose an Agent", systemImage: "sparkles",
                            description: Text("See its instructions, trigger, access and recent activity."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("configureAgent.agents")
    }

    private var agentList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(LocusTheme.muted)
                TextField("Find an Agent", text: $search).textFieldStyle(.plain)
                    .accessibilityIdentifier("configureAgent.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.locus(.icon)).accessibilityLabel("Clear Agent search")
                }
            }.padding(9).background(LocusTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 7))
            Picker("Filter Agents", selection: $agentFilter) {
                Text("All Agents").tag("all")
                Text("Enabled").tag("enabled")
                Text("Paused").tag("paused")
                Text("Needs attention").tag("attention")
            }.labelsHidden().accessibilityIdentifier("configureAgent.filter")
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredReferences) { reference in
                        if let definition = definition(for: reference) {
                            agentListRow(reference, definition: definition)
                        }
                    }
                    if filteredReferences.isEmpty {
                        Text("No matching Agents").font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).padding(.vertical, 24)
                        Button("Clear filters") { search = ""; agentFilter = "all" }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(12).frame(width: 230)
    }

    private func agentListRow(_ reference: AgentConfigurationReference, definition: AgentDefinition) -> some View {
        let value = overview(definition)
        return Button { selectionID = reference.id } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: reference.kind.symbol)
                    .foregroundStyle(LocusTheme.signalDeep).frame(width: 20, height: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(reference.title).font(.locus(size: 11, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(value)).frame(width: 5, height: 5)
                        Text(statusTitle(value)).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionID == reference.id ? LocusTheme.signal.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus(.quiet))
        .accessibilityAddTraits(selectionID == reference.id ? .isSelected : [])
        .accessibilityLabel("\(reference.title), \(statusTitle(value)), \(reference.kind.title)")
        .accessibilityIdentifier("configureAgent.\(reference.kind == .schedule ? "timeTrigger" : "eventTrigger").\(reference.configurationID)")
    }

    private func agentDetail(_ definition: AgentDefinition) -> some View {
        let value = overview(definition)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(value.name).font(.locus(size: 19, weight: .bold)).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Menu {
                            Button("Delete Agent…", role: .destructive) { pendingAgentRemoval = definition }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Agent actions")
                    }
                    Label(statusTitle(value), systemImage: value.runningChatCount > 0 ? "circle.dotted" : "circle.fill")
                        .font(.locus(size: 9, weight: .medium)).foregroundStyle(statusColor(value))
                        .accessibilityIdentifier("configureAgent.detail.status")
                    Text(value.status.detail(for: value.vocabulary))
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    detailActions(definition, overview: value)
                }
                if let error = value.lastError {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Needs attention", systemImage: "exclamationmark.triangle")
                            .font(.locus(size: 10, weight: .semibold))
                        Text(error).font(.locus(size: 9)).textSelection(.enabled)
                        Button("Inspect activity") { showHistory(definition) }.buttonStyle(.bordered)
                    }
                    .foregroundStyle(LocusTheme.warning).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
                Divider()
                detailSection("Instructions", symbol: "text.alignleft") {
                    Text(value.instruction.isEmpty ? "No instructions saved. Edit this Agent to add them." : value.instruction)
                        .font(.locus(size: 11)).foregroundStyle(LocusTheme.inkSoft)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                detailSection("Trigger", symbol: definition.isSchedule ? "calendar.badge.clock" : "bolt") {
                    Text(value.summary).font(.locus(size: 10, weight: .medium))
                    if let trigger = definition.trigger {
                        let connection = automation.connections.first { $0.id == trigger.connectionID }
                        Text(connection.map { "Connection · \($0.enabled ? $0.health.capitalized : "Disabled")" } ?? "Source connection is missing. Edit this Agent to choose another.")
                            .font(.locus(size: 9)).foregroundStyle(connectionNeedsAttention(value) ? LocusTheme.warning : LocusTheme.muted)
                    }
                    ForEach(value.filters, id: \.self) { filter in
                        Text(filter).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                    if let task = definition.schedule {
                        Text(task.enabled
                             ? (task.nextRunDate.map { "Next run · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No upcoming run")
                             : "Schedule paused — automatic runs are off")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                    if let price = value.priceState { Text(price).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted) }
                    if let date = value.lastEventAt {
                        Text("Last triggered · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                }
                Divider()
                detailSection("Access & environment", symbol: "lock.shield") {
                    ForEach(value.facts.filter { !["Created", "Next run", "Source", "Connection"].contains($0.label) }) { fact in
                        HStack(alignment: .top, spacing: 12) {
                            Text(fact.label).foregroundStyle(LocusTheme.muted)
                            Spacer(minLength: 4)
                            Text(fact.value).multilineTextAlignment(.trailing)
                                .foregroundStyle(fact.isWarning ? LocusTheme.warning : LocusTheme.inkSoft)
                        }.font(.locus(size: 9))
                    }
                    Text(definition.isSchedule
                         ? "Uses the app’s permission policy when a run starts. Approvals pause the run and notify you."
                         : "File changes, commands and external actions follow Locus’s shared approval policy. Connected services above are the ones this trigger may act through.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    Text("Runs on this Mac while Locus is open.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Divider()
                detailSection("Recent activity", symbol: "clock.arrow.circlepath") {
                    let records = activityRecords.filter { $0.agent.id == AgentInspectorAgent(definition).id }
                    if let record = records.first {
                        activityRow(record)
                    } else {
                        Text("No recorded runs yet. Activity appears when this Agent is triggered.")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                    Button("View activity") { showHistory(definition) }
                        .buttonStyle(.locus()).foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("configureAgent.detail.activity")
                }
            }.padding(22)
        }.accessibilityIdentifier("configureAgent.detail")
    }

    private func detailActions(_ definition: AgentDefinition, overview: AgentOverview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { primaryDetailActions(definition); secondaryDetailActions(definition, overview: overview) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) { primaryDetailActions(definition) }
                HStack(spacing: 7) { secondaryDetailActions(definition, overview: overview) }
            }
        }.padding(.top, 5)
    }

    @ViewBuilder private func primaryDetailActions(_ definition: AgentDefinition) -> some View {
        Button("Open Agent") {
            app.dismissConfigureAgent()
            app.selectAgent(AgentInspectorAgent(definition))
        }.buttonStyle(.borderedProminent).accessibilityIdentifier("configureAgent.detail.open")
        Button("Edit") {
            if let task = definition.schedule { app.presentScheduleEditor(task: task) }
            else if let trigger = definition.trigger {
                automation.presentEditor(trigger: trigger, targetSessionID: trigger.targetSessionID,
                    isDedicatedAgent: sessionCatalog.snapshot.sessionsByID[trigger.targetSessionID]?.isAgentChat == true)
            }
        }.buttonStyle(.bordered).accessibilityIdentifier("configureAgent.detail.edit")
    }

    @ViewBuilder private func secondaryDetailActions(_ definition: AgentDefinition, overview: AgentOverview) -> some View {
        if definition.isSchedule {
            Button("Run now") { app.runAgentNow(definition) }.buttonStyle(.bordered)
                .accessibilityIdentifier("configureAgent.detail.runNow")
        }
        if overview.canRearm, let trigger = definition.trigger {
            Button("Re-arm") { automation.rearm(trigger) }.buttonStyle(.bordered)
        }
        Button(definition.enabled ? "Pause" : "Resume") {
            app.setAgentEnabled(definition, enabled: !definition.enabled)
        }.buttonStyle(.bordered).disabled(app.isChangingAgentEnabled(definition))
            .help("Pausing stops automatic starts. A run already in progress can continue.")
            .accessibilityIdentifier("configureAgent.detail.toggle")
    }

    private func detailSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.locus(size: 11, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runHistoryTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Activity", detail: "Recent scheduled runs and incoming events, together. Inspect a record for actions, outputs and errors.")
            HStack {
                Picker("Agent", selection: $historyAgentID) {
                    Text("All Agents").tag("")
                    ForEach(references) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 250)
                    .accessibilityIdentifier("configureAgent.history.configuration")
                Spacer()
                Picker("Status", selection: $historyFilter) {
                    ForEach(AgentActivityFilter.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 165).accessibilityIdentifier("configureAgent.history.status")
            }
            Divider()
            if !schedule.occurrenceLoadErrors.isEmpty {
                errorBanner("Some scheduled activity couldn’t be loaded. Refresh to try again.")
            }
            if isLoadingActivity && activityRecords.isEmpty { loadingState("Loading activity…") }
            else if filteredActivity.isEmpty {
                ContentUnavailableView(activityRecords.isEmpty ? "No activity yet" : "No matching activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(activityRecords.isEmpty
                        ? "When a schedule runs or an event arrives, its progress and result appear here."
                        : "Choose another Agent or status to see more activity."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredActivity) { record in
                            activityRow(record).padding(.vertical, 13)
                            Divider()
                        }
                    }
                }
                Text("Showing recent loaded activity. Open a record to inspect its execution and retained Agent history.")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            }
        }.padding(20).accessibilityIdentifier("configureAgent.runHistory")
    }

    private func activityRow(_ record: AgentActivityRecord) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: record.symbol).foregroundStyle(activityColor(record))
                .frame(width: 22, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.agentName).font(.locus(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 5)
                    Text(record.statusTitle).font(.locus(size: 9, weight: .medium))
                        .foregroundStyle(activityColor(record))
                }
                Text(record.title).font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft).lineLimit(2)
                Text("\(record.sourceTitle) · \(Date(timeIntervalSince1970: record.timestamp).formatted(date: .abbreviated, time: .shortened))")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                if let error = record.error, !error.isEmpty {
                    Text(error).font(.locus(size: 9)).foregroundStyle(record.needsAttention ? LocusTheme.warning : LocusTheme.muted).lineLimit(2)
                }
                HStack(spacing: 12) {
                    Button("Inspect") {
                        app.dismissConfigureAgent()
                        app.selectAgent(record.agent)
                        app.agentInspector.show(record.context)
                    }.accessibilityIdentifier("configureAgent.activity.\(record.id).inspect")
                    if let delivery = record.delivery, record.canRetry {
                        Button(automation.retryingDeliveryIDs.contains(delivery.id) ? "Retrying…" : "Retry") {
                            automation.retry(delivery)
                        }.disabled(automation.retryingDeliveryIDs.contains(delivery.id))
                    }
                }.buttonStyle(.locus()).font(.locus(size: 9, weight: .semibold)).foregroundStyle(LocusTheme.signalDeep)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("configureAgent.activity.\(record.id)")
    }

    private var sourcesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    sectionHeading("Connections", detail: "Shared sources that can start an Agent or provide allowed actions.")
                    Spacer()
                    Menu {
                        ForEach(ConnectorKind.allCases) { kind in
                            Button { connectionSheet = kind } label: { Label(kind.title, systemImage: kind.symbol) }
                        }
                    } label: { Label("Connect source", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("eventAutomations.addConnection")
                }
                if automation.connections.isEmpty {
                    Text("Choose a source to get started. Then use it in an Agent’s incoming event trigger.")
                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
                    ForEach(ConnectorKind.allCases) { kind in
                        Button { connectionSheet = kind } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind.symbol).foregroundStyle(LocusTheme.signalDeep).frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(kind.title).font(.locus(size: 11, weight: .semibold))
                                    Text(connectionDescription(kind)).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "plus")
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.locus(.card)).accessibilityIdentifier("configureAgent.connect.\(kind.rawValue)")
                        Divider()
                    }
                } else {
                    ForEach(automation.connections) { connection in
                        sourceRow(connection)
                        Divider()
                    }
                }
                Label("Credentials are stored in your Mac’s Keychain and kept out of chats.", systemImage: "lock.shield")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            }.padding(20)
        }.accessibilityIdentifier("configureAgent.sources")
    }

    private func sourceRow(_ connection: ConnectorConnection) -> some View {
        let users = automation.triggers.filter { $0.connectionID == connection.id || $0.actionConnectionIDs.contains(connection.id) }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: connection.kind.symbol).font(.locus(size: 16))
                .foregroundStyle(LocusTheme.signalDeep).frame(width: 30, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(connection.displayName).font(.locus(size: 12, weight: .semibold))
                    Text(connection.enabled ? connection.health.replacingOccurrences(of: "_", with: " ").capitalized : "Disabled")
                        .font(.locus(size: 9)).foregroundStyle(connection.lastError == nil ? LocusTheme.muted : LocusTheme.warning)
                }
                Text("\(connection.kind.title) · \(users.count) \(users.count == 1 ? "Agent" : "Agents")")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                if !users.isEmpty {
                    Text(users.map(\.name).joined(separator: ", "))
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).lineLimit(2)
                }
                if let date = connection.lastPolledAt {
                    Text("Last checked \(Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .shortened))")
                        .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                }
                if let error = connection.lastError, !error.isEmpty {
                    Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.warning).textSelection(.enabled)
                }
                if !users.isEmpty {
                    Text("To remove this connection, first update the Agents using it.")
                        .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                }
            }
            Spacer(minLength: 4)
            Button("Remove…", role: .destructive) { pendingConnectionRemoval = connection }
                .buttonStyle(.bordered).disabled(!users.isEmpty)
                .help(users.isEmpty ? "Remove connection" : "This connection is used by \(users.count) Agents")
        }.padding(.vertical, 10).accessibilityIdentifier("configureAgent.source.\(connection.id)")
    }

    private var runtimeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sectionHeading("Runtime", detail: "Shared controls for how chats and Agents work on this Mac.")
                detailSection("Concurrent work", symbol: "arrow.triangle.branch") {
                    Text("Choose how many chats and Agent events can work at once.")
                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
                    Picker("Concurrent work", selection: Binding(get: { app.settings.maximumActiveChats }, set: { value in
                        var settings = app.settings
                        settings.maximumActiveChats = value
                        app.applySettings(settings, showConfirmation: false)
                        app.showToast("Concurrent work updated")
                    })) {
                        Text("1 · One at a time").tag(1)
                        Text("2 at a time").tag(2)
                        Text("3 at a time").tag(3)
                        Text("4 at a time").tag(4)
                    }.labelsHidden().frame(maxWidth: 270)
                        .accessibilityIdentifier("configureAgent.maximumActiveChats")
                    Text("Events in the same chat run in arrival order. Chats that can change the same shared folder wait until it is free.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }.accessibilityIdentifier("configureAgent.eventProcessing")
                Divider()
                detailSection("Where Agents run", symbol: "desktopcomputer") {
                    Text("Locus coordinates automatic work on this Mac. Keep the app open and your model and connections available.")
                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
                    Text("An Agent’s environment determines whether it works directly in a workspace or in an isolated worktree. Its selected model may be local or hosted.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Divider()
                detailSection("Behavior & teams", symbol: "person.3") {
                    Text("Reusable specialists and teams define how models collaborate. Manage them in Settings.")
                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
                    Button("Specialists & teams…") { app.dismissConfigureAgent(); app.presentSettings(.agents) }
                        .buttonStyle(.bordered)
                }
            }.padding(24)
        }.accessibilityIdentifier("configureAgent.center")
    }

    private var creationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create an Agent").font(.locus(size: 20, weight: .bold))
                    Text("What should start its work?").font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button { app.configureAgentCreationPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.locus(.icon)).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel Agent creation")
            }
            Text("Add instructions, choose a trigger, and give your Agent a place to work. You can chat with it and refine its setup at any time.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
            if !app.configureAgentDraftSuggestion.isEmpty {
                Text(app.configureAgentDraftSuggestion).font(.locus(size: 10)).lineLimit(3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.signal.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(spacing: 8) {
                creationOption(.schedule, title: "On a schedule", detail: "A daily review, a weekly report, or a one-time task.")
                creationOption(.event, title: "When an event arrives", detail: "React to Gmail, Telegram, or a signed webhook.")
                creationOption(.price, title: "When a price changes", detail: "Watch a stock or crypto price and act at a threshold.")
            }
            Text("Automatic work runs while Locus is open. You stay in control of its access and can pause it at any time.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
        }.padding(26).frame(width: 560).background(LocusTheme.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("configureAgent.creation")
    }

    private func creationOption(_ kind: AgentConfigurationKind, title: String, detail: String) -> some View {
        Button {
            chosenCreationKind = kind
            app.configureAgentCreationPresented = false
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol).font(.locus(size: 18, weight: .medium))
                    .foregroundStyle(LocusTheme.signalDeep).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.locus(size: 12, weight: .semibold)).foregroundStyle(LocusTheme.ink)
                    Text(detail).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.locus(size: 9, weight: .semibold)).foregroundStyle(LocusTheme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LocusTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.buttonStyle(.locus(.card)).accessibilityIdentifier("configureAgent.create.\(kind.rawValue)")
    }

    private func openChosenEditor() {
        guard let kind = chosenCreationKind else { return }
        chosenCreationKind = nil
        guard app.configureAgentPresented else { return }
        if kind == .schedule { app.presentScheduleEditor(prompt: app.configureAgentDraftSuggestion) }
        else {
            automation.presentEditor(targetSessionID: app.currentSessionID,
                naturalLanguageRequest: app.configureAgentDraftSuggestion,
                triggerKind: kind == .price ? .price : .event)
        }
    }

    private var references: [AgentConfigurationReference] {
        let schedules = schedule.scheduledTasks.map { AgentConfigurationReference(kind: .schedule, configurationID: $0.id, title: $0.name) }
        let triggers = automation.triggers.map { AgentConfigurationReference(kind: $0.triggerKind == .price ? .price : .event, configurationID: $0.id, title: $0.name) }
        return (schedules + triggers).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var filteredReferences: [AgentConfigurationReference] {
        references.filter { reference in
            guard let definition = definition(for: reference) else { return false }
            let matches = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || "\(reference.title) \(definition.trigger?.instruction ?? definition.schedule?.prompt ?? "") \(reference.kind.title)".localizedCaseInsensitiveContains(search)
            let stateMatches = agentFilter == "all" || (agentFilter == "enabled" && definition.enabled)
                || (agentFilter == "paused" && !definition.enabled)
                || (agentFilter == "attention" && statusTitle(overview(definition)) == "Needs attention")
            return matches && stateMatches
        }
    }
    private var selectedDefinition: AgentDefinition? { references.first { $0.id == selectionID }.flatMap(definition) }
    private func definition(for reference: AgentConfigurationReference) -> AgentDefinition? {
        if reference.kind == .schedule { return schedule.scheduledTasks.first { $0.id == reference.configurationID }.map(AgentDefinition.schedule) }
        return automation.triggers.first { $0.id == reference.configurationID }.map(AgentDefinition.trigger)
    }
    private func overview(_ definition: AgentDefinition) -> AgentOverview {
        AgentOverview.resolve(agentID: definition.id, definition: definition, ownershipDefinitions: app.agentDefinitions,
            connections: automation.connections, actionConnections: automation.connections,
            sessions: sessionCatalog.snapshot.sessions, deliveries: automation.deliveries,
            occurrences: schedule.occurrencesBySchedule[definition.id] ?? [], currentSessionID: app.currentSessionID,
            runningSessionIDs: app.runningChatSessionIDs, startedAt: app.runningChatStartTimes)
    }
    private func connectionNeedsAttention(_ value: AgentOverview) -> Bool {
        guard automation.hasLoaded else { return false }
        return AgentInspectorCopy.sourceNeedsAttention(definition: value.definition, connection: value.connection)
    }
    private func statusTitle(_ value: AgentOverview) -> String {
        AgentInspectorCopy.agentStatusTitle(value.status, vocabulary: value.vocabulary,
            isRunning: value.runningChatCount > 0, sourceNeedsAttention: connectionNeedsAttention(value))
    }
    private func statusColor(_ value: AgentOverview) -> Color {
        if value.runningChatCount > 0 { return LocusTheme.signalDeep }
        if value.lastError?.isEmpty == false || connectionNeedsAttention(value) { return LocusTheme.warning }
        return value.status == .active ? LocusTheme.success : LocusTheme.muted
    }
    private var activityRecords: [AgentActivityRecord] {
        AgentActivityRecord.merged(deliveries: automation.deliveries,
            occurrences: schedule.occurrencesBySchedule.values.flatMap { $0 }, definitions: app.agentDefinitions)
    }
    private var filteredActivity: [AgentActivityRecord] {
        activityRecords.filter { record in
            let reference = references.first { $0.id == historyAgentID }
            let matchesAgent = historyAgentID.isEmpty || reference.map {
                $0.configurationID == record.agent.agentID && ($0.kind == .schedule) == (record.agent.kind == .schedule)
            } == true
            return matchesAgent && historyFilter.includes(record)
        }
    }
    private func activityColor(_ record: AgentActivityRecord) -> Color {
        if record.needsAttention { return LocusTheme.warning }
        if record.isInProgress { return LocusTheme.signalDeep }
        return record.state == "completed" ? LocusTheme.success : LocusTheme.muted
    }
    private func showHistory(_ definition: AgentDefinition) {
        historyAgentID = references.first { $0.configurationID == definition.id && ($0.kind == .schedule) == definition.isSchedule }?.id ?? ""
        historyFilter = .all
        app.configureAgentTab = .runHistory
    }
    private func normalizeSelection() {
        if !references.contains(where: { $0.id == selectionID }) {
            let current = app.inspectedAgentReference
            selectionID = references.first { reference in
                reference.configurationID == current?.agentID && (reference.kind == .schedule) == (current?.kind == .schedule)
            }?.id ?? references.first?.id
        }
        if !historyAgentID.isEmpty && !references.contains(where: { $0.id == historyAgentID }) { historyAgentID = "" }
    }
    private func applyRequestedFocus() {
        guard let id = app.configureAgentFocusConfigurationID, references.contains(where: { $0.id == id }) else { return }
        selectionID = id
        historyAgentID = id
        historyFilter = .all
        app.configureAgentFocusConfigurationID = nil
    }
    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.locus(size: 17, weight: .bold))
            Text(detail).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func loadingState(_ title: String) -> some View {
        VStack(spacing: 12) { ProgressView(); Text(title).font(.locus(size: 10)).foregroundStyle(LocusTheme.muted) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(LocusTheme.warning)
            Text(error).font(.locus(size: 9)).textSelection(.enabled)
            Spacer()
            Button("Retry") { Task { await refresh(); await refreshActivity() } }.buttonStyle(.bordered)
        }.padding(12).background(LocusTheme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
    private func connectionDescription(_ kind: ConnectorKind) -> String {
        switch kind {
        case .gmail: "Start work when matching email arrives."
        case .telegram: "Receive messages and commands from your bot."
        case .webhook: "Receive signed events from integrations and apps."
        case .priceFeed: "Read stock or crypto quotes for price alerts."
        }
    }
    @MainActor private func refresh() async {
        async let events: Void = automation.refresh(announceFailure: false)
        async let schedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
        _ = await (events, schedules)
    }
    @MainActor private func refreshActivity() async {
        guard !isLoadingActivity else { return }
        isLoadingActivity = true
        defer { isLoadingActivity = false }
        // Bound requests for large fleets rather than sending one hundred at once.
        let tasks = schedule.scheduledTasks
        for start in stride(from: 0, to: tasks.count, by: 4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for task in tasks[start..<min(start + 4, tasks.count)] {
                    group.addTask { await schedule.refreshOccurrences(for: task, announceFailure: false) }
                }
            }
        }
    }
}

private struct AgentConfigurationReference: Identifiable, Hashable {
    let kind: AgentConfigurationKind
    let configurationID: String
    let title: String
    var id: String { "\(kind.rawValue):\(configurationID)" }
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
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @State private var draft: EventTriggerEditorDraft
    @State private var connectionSheet: ConnectorKind?
    @State private var showFilters = false
    @State private var showEnvironment = false
    @State private var showActions = false
    @State private var showWorkflow = false
    @State private var confirmsDiscard = false
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool
    private let originalDraft: EventTriggerEditorDraft
    @ObservedObject var automation: EventAutomationModel
    let sessions: [SessionSummary]
    let currentModel: String

    init(draft: EventTriggerEditorDraft, automation: EventAutomationModel,
         sessions: [SessionSummary], currentModel: String) {
        _draft = State(initialValue: draft)
        originalDraft = draft
        self.automation = automation
        self.sessions = sessions
        self.currentModel = currentModel
        _showFilters = State(initialValue: draft.id != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: draft.triggerKind == .price ? "chart.line.uptrend.xyaxis" : "bolt")
                    .font(.locus(size: 19)).foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 38, height: 38)
                    .background(LocusTheme.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(editorTitle).font(.locus(size: 17, weight: .bold))
                    Text("Give it a purpose. Choose what wakes it up.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Spacer()
            }.padding(20)
            Divider()
            Form {
                Section("Agent") {
                    TextField("Name", text: $draft.name).focused($nameFocused)
                        .accessibilityIdentifier("eventTrigger.name")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions").font(.locus(size: 10, weight: .semibold))
                        TextEditor(text: instructionBinding)
                            .font(.locus(size: 11)).foregroundStyle(LocusTheme.inkSoft)
                            .tint(LocusTheme.signalDeep).scrollContentBackground(.hidden)
                            .frame(minHeight: 95).padding(7)
                            .background(LocusTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                if instructionBinding.wrappedValue.isEmpty {
                                    Text("When an event arrives, what should this Agent do?")
                                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
                                        .padding(12).allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Instructions").accessibilityIdentifier("eventTrigger.instruction")
                        Text("For example: Summarize the email, extract action items, and draft a reply for me to review.")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                }
                Section("Trigger") {
                    if draft.id == nil {
                        Picker("Start work", selection: $draft.triggerKind) {
                            Text("Incoming event").tag(EventTriggerKind.event)
                            Text("Price alert").tag(EventTriggerKind.price)
                        }
                        .onChange(of: draft.triggerKind) { _, kind in
                            draft.connectionID = ""
                            draft.actionConnectionIDs = []
                            draft.filters = EventTriggerFilters()
                            if kind == .price { draft.filters.priceCondition = PriceCondition() }
                        }
                    }
                    Picker("Source", selection: $draft.connectionID) {
                        Text(eligibleConnections.isEmpty ? "Connect a source below" : "Choose a source").tag("")
                        ForEach(eligibleConnections) { Text($0.displayName).tag($0.id) }
                    }.accessibilityIdentifier("eventTrigger.connection")
                    .onChange(of: draft.connectionID) { _, value in
                        let kind = automation.connections.first { $0.id == value }?.kind
                        if draft.triggerKind == .price {
                            draft.actionConnectionIDs = []
                            draft.filters.eventNames = kind == .webhook ? ["price.quote"] : []
                        }
                        // Selecting an event source never grants permission to
                        // send messages through it; actions have their own controls.
                    }
                    Menu {
                        ForEach(addableConnectorKinds) { kind in
                            Button { connectionSheet = kind } label: { Label(kind.title, systemImage: kind.symbol) }
                                .accessibilityIdentifier("eventTrigger.addSource.\(kind.rawValue)")
                        }
                    } label: {
                        Label(eligibleConnections.isEmpty ? "Connect a source…" : "Add a source…", systemImage: "plus")
                    }.menuStyle(.borderlessButton).accessibilityIdentifier("eventTrigger.addSource")
                    if draft.triggerKind == .price { sourceFilters }
                    else if !draft.connectionID.isEmpty {
                        DisclosureGroup(isExpanded: $showFilters) { sourceFilters } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Only matching events").font(.locus(size: 10, weight: .medium))
                                Text(filterSummary).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                            }
                        }.accessibilityIdentifier("eventTrigger.filters")
                    }
                }
                Section("Access") {
                    DisclosureGroup(isExpanded: $showActions) {
                        ForEach(actionConnections) { connection in
                            Toggle(isOn: Binding(get: { draft.actionConnectionIDs.contains(connection.id) }, set: { enabled in
                                draft.actionConnectionIDs.removeAll { $0 == connection.id }
                                if enabled { draft.actionConnectionIDs.append(connection.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.displayName)
                                    Text(connection.kind == .gmail ? "Allow email actions, including sending" : "Allow actions through this Telegram bot")
                                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                                }
                            }.accessibilityIdentifier("eventTrigger.action.\(connection.id)")
                        }
                        if actionConnections.isEmpty {
                            Text("No services with external actions are connected.").foregroundStyle(LocusTheme.muted)
                        }
                        Text("Webhooks and price feeds only supply events. They cannot perform external actions.")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connected-service actions").font(.locus(size: 10, weight: .medium))
                            Text(actionSummary).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                        }
                    }.accessibilityIdentifier("eventTrigger.actions")
                    Text("File edits, commands, network requests and external actions follow Locus’s shared approval policy. Approvals can pause a run until you respond.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Section {
                    DisclosureGroup(isExpanded: $showEnvironment) { environmentFields } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Environment & conversation").font(.locus(size: 10, weight: .medium))
                            Text("\(draft.targetSessionID == EventTriggerEditorDraft.dedicatedAgentChat ? "Dedicated Agent chat" : "Existing chat") · \(existingAgentModel ?? currentModel)")
                                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).lineLimit(2)
                        }
                    }.accessibilityIdentifier("eventTrigger.environment")
                    if app.automationWorkflowsEnabled {
                        DisclosureGroup("Advanced workflow", isExpanded: $showWorkflow) {
                            AutomationWorkflowEditorView(workflow: $draft.workflow, connectors: workflowConnectorOptions)
                            Text("The instructions above are the first Agent step. Additional steps run in the saved workflow order.")
                                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                        }.accessibilityIdentifier("eventTrigger.workflow")
                    }
                    Toggle(draft.id == nil ? "Enable after creation" : "Trigger enabled", isOn: $draft.enabled)
                        .accessibilityIdentifier("eventTrigger.enabled")
                    Text(draft.enabled ? "Starts automatically when a matching event arrives while Locus is open." : "Saved paused. You can review its setup before enabling automatic work.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).background(LocusTheme.surfaceCanvas)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let saveError {
                    Text(saveError).font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
                        .accessibilityIdentifier("eventTrigger.error")
                }
                HStack(alignment: .center, spacing: 16) {
                    Text(missingRequirement ?? (draft.enabled ? "Ready to start listening" : "Ready to create paused"))
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("eventTrigger.requirement")
                    Spacer(minLength: 4)
                    if automation.isSaving { ProgressView().controlSize(.small) }
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(automation.isSaving)
                    Button(automation.isSaving ? "Saving…" : (draft.id == nil ? "Create Agent" : "Save changes")) {
                        saveError = nil
                        Task {
                            if await automation.saveTrigger(draft) { dismiss() }
                            else { saveError = "Couldn’t save this Agent. Review its source and destination, then try again." }
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(automation.isSaving || missingRequirement != nil)
                        .accessibilityIdentifier("eventTrigger.save")
                }
            }.padding(18)
        }
        .frame(width: 680, height: 620).background(LocusTheme.panel)
        .tint(LocusTheme.accentAction)
        .interactiveDismissDisabled(draft != originalDraft || automation.isSaving)
        .alert("Discard changes?", isPresented: $confirmsDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        } message: { Text("Your Agent settings haven’t been saved.") }
        .sheet(item: $connectionSheet) { ConnectorSetupView(kind: $0, automation: automation) }
        .onAppear { nameFocused = draft.name.isEmpty }
        .onChange(of: automation.connections.map(\.id)) { oldValue, newValue in
            guard draft.connectionID.isEmpty,
                  let added = Set(newValue).subtracting(oldValue).first,
                  eligibleConnections.contains(where: { $0.id == added }) else { return }
            draft.connectionID = added
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eventAutomations.editor")
    }

    private var instructionBinding: Binding<String> {
        Binding(get: { draft.workflow.firstAgent?.instructionTemplate ?? draft.instruction }, set: { value in
            draft.instruction = value
            if let index = draft.workflow.steps.firstIndex(where: { $0.type == .agent }) {
                draft.workflow.steps[index].instructionTemplate = value
            }
        })
    }
    private var actionConnections: [ConnectorConnection] {
        automation.connections.filter { $0.kind != .webhook && $0.kind != .priceFeed }
    }
    private var actionSummary: String {
        let names = actionConnections.filter { draft.actionConnectionIDs.contains($0.id) }.map(\.displayName)
        return names.isEmpty ? "No external service actions allowed" : "Allowed: " + names.joined(separator: ", ")
    }
    private var filterSummary: String {
        let chips = AgentOverview.filterChips(for: draft.filters, kind: draft.triggerKind)
        return chips.isEmpty ? "All incoming events · add optional filters" : chips.joined(separator: " · ")
    }
    private func cancel() {
        if draft != originalDraft { confirmsDiscard = true } else { dismiss() }
    }
    @ViewBuilder private var environmentFields: some View {
        Picker("Conversation", selection: $draft.targetSessionID) {
            Text("Its own Agent chat").tag(EventTriggerEditorDraft.dedicatedAgentChat)
            Text("Choose an existing chat").tag("")
            ForEach(sessions.filter { !$0.isArchived }) { Text($0.displayTitle).tag($0.id) }
        }
        if draft.targetSessionID == EventTriggerEditorDraft.dedicatedAgentChat {
            Text("Matching events continue the same Agent chat. Side conversations stay separate. The Agent uses the selected workspace’s files and instructions.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            if draft.id != nil, let model = existingAgentModel {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.adoptCurrentRoute ? "Will use \(currentModel) after saving." : "Model: \(model)")
                    if !draft.adoptCurrentRoute, currentModel != model {
                        Button("Switch to \(currentModel)") { draft.adoptCurrentRoute = true }
                            .accessibilityIdentifier("eventTrigger.route.adopt")
                    }
                }.font(.locus(size: 9)).accessibilityIdentifier("eventTrigger.route")
            } else {
                Text("Model: \(currentModel)").font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            }
        }
        Picker("Work mode", selection: $draft.mode) {
            ForEach(WorkMode.allCases) { Text($0.title).tag($0) }
        }.onChange(of: draft.mode) { _, mode in
            if let index = draft.workflow.steps.firstIndex(where: { $0.type == .agent }) { draft.workflow.steps[index].mode = mode }
        }
        if app.automationWorkflowsEnabled {
            Picker("Runner", selection: $draft.runner) {
                ForEach(ScheduleRunner.selectableCases) { Text($0.title).tag($0) }
            }
            if draft.runner == .team {
                Picker("Team", selection: $draft.teamID) {
                    Text("Choose a team").tag(String?.none)
                    ForEach(agentTeams.agentTeams) { Text($0.name).tag(Optional($0.id.uuidString)) }
                }.onChange(of: draft.teamID) { _, value in
                    draft.teamName = agentTeams.agentTeams.first { $0.id.uuidString == value }?.name ?? ""
                }
            }
        }
        Text("Incoming message bodies are event data. They cannot change this Agent’s instructions or permissions.")
            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
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
            Text("Choose a source to set optional matching conditions.")
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
        if !eligibleConnections.contains(where: { $0.id == draft.connectionID }) {
            return "Choose an available source for this Agent."
        }
        if draft.targetSessionID.isEmpty {
            return "Choose where this Agent’s events arrive."
        }
        if draft.targetSessionID == EventTriggerEditorDraft.dedicatedAgentChat {
            if draft.templateSessionID.isEmpty || !sessions.contains(where: { $0.id == draft.templateSessionID }) {
                return "Open a workspace chat before creating this Agent."
            }
        } else if !sessions.contains(where: { $0.id == draft.targetSessionID && !$0.isArchived }) {
            return "Choose an available receiving chat."
        }
        let instruction = app.automationWorkflowsEnabled
            ? (draft.workflow.firstAgent?.instructionTemplate ?? "")
            : draft.instruction
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write what this agent should do with each event."
        }
        if app.automationWorkflowsEnabled, draft.runner == .team,
           draft.teamID.flatMap(UUID.init(uuidString:)) == nil {
            return "Choose the Team that handles each event."
        }
        if draft.triggerKind == .price {
            guard draft.filters.priceCondition?.providerSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "Add the price provider’s symbol, such as BTCUSDT."
            }
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

    private var workflowConnectorOptions: [WorkflowConnectorOption] {
        automation.connections.compactMap { connection in
            guard draft.actionConnectionIDs.contains(connection.id) else { return nil }
            return WorkflowConnectorOption(id: connection.id, name: connection.displayName)
        }
    }

    private var editorTitle: String {
        if draft.id != nil { return "Edit Agent" }
        return draft.triggerKind == .price ? "New Price Alert Agent" : "New Event Agent"
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
