import AppKit
import SwiftUI

struct ConfigureAgentView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var automation: EventAutomationModel
    @ObservedObject var schedule: ScheduleModel
    @State private var connectionSheet: ConnectorKind?
    @State private var selectedTriggerID: String?
    @State private var selectedScheduleID: String?

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionsSection
                    configurationsSection
                }
                .padding(20)
            }
            .frame(minWidth: 390)
            .accessibilityIdentifier("configureAgent.center")

            deliveryHistory
                .frame(minWidth: 290, idealWidth: 360)
        }
        .sheet(item: $connectionSheet) { kind in
            ConnectorSetupView(kind: kind, automation: automation)
        }
        .sheet(item: $automation.editorDraft) { draft in
            EventTriggerEditorView(
                draft: draft,
                automation: automation,
                sessions: app.sessions
            )
        }
        .sheet(item: $automation.webhookSetup) { setup in
            WebhookSecretView(setup: setup)
        }
        .task {
            async let refreshEvents: Void = automation.refresh(announceFailure: false)
            async let refreshSchedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
            _ = await (refreshEvents, refreshSchedules)
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources")
                    .font(.locus(size: 11, weight: .bold))
                Spacer()
                Menu {
                    ForEach(ConnectorKind.allCases) { kind in
                        Button { connectionSheet = kind } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("eventAutomations.addConnection")
            }
            if automation.connections.isEmpty {
                Text("Connect Gmail, Telegram, a signed webhook, or a read-only price source.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            } else {
                ForEach(automation.connections) { connection in
                    HStack(spacing: 9) {
                        Image(systemName: connection.kind.symbol)
                            .frame(width: 18)
                            .foregroundStyle(connection.health == "error"
                                ? LocusTheme.warning : LocusTheme.signalDeep)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.displayName)
                                .font(.locus(size: 10, weight: .semibold))
                            Text("\(connection.kind.title) · \(connection.health.replacingOccurrences(of: "_", with: " "))")
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                            if let error = connection.lastError, !error.isEmpty {
                                Text(error)
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.warning)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            automation.deleteConnection(connection)
                        }
                        .buttonStyle(ActivityActionButtonStyle())
                        .disabled(automation.triggers.contains { $0.connectionID == connection.id })
                    }
                    .padding(10)
                    .background(LocusTheme.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line) }
                }
            }
        }
    }

    private var configurationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Configurations")
                    .font(.locus(size: 11, weight: .bold))
                Spacer()
                Menu {
                    Button {
                        app.presentScheduleEditor()
                    } label: {
                        Label("Time Trigger", systemImage: "calendar.badge.clock")
                    }
                    Button {
                        automation.presentEditor(
                            targetSessionID: app.currentSessionID,
                            triggerKind: .event
                        )
                    } label: {
                        Label("Incoming Event", systemImage: "bolt.badge.clock")
                    }
                    Button {
                        automation.presentEditor(
                            targetSessionID: app.currentSessionID,
                            triggerKind: .price
                        )
                    } label: {
                        Label("Price Alert", systemImage: "chart.line.uptrend.xyaxis")
                    }
                } label: {
                    Label("New Configuration", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("configureAgent.newConfiguration")
            }
            if automation.triggers.isEmpty && schedule.scheduledTasks.isEmpty {
                Text("Time, incoming-event, and price conditions can start work while Locus is open.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            } else {
                ForEach(schedule.scheduledTasks) { task in
                    TimeTriggerRow(
                        task: task,
                        selected: selectedScheduleID == task.id,
                        onSelect: {
                            selectedScheduleID = task.id
                            selectedTriggerID = nil
                            Task { await schedule.refreshOccurrences(for: task) }
                        },
                        onEdit: { app.presentScheduleEditor(task: task) },
                        onRun: { schedule.runScheduleNow(task) },
                        onToggle: { schedule.setScheduleEnabled(task, enabled: !task.enabled) },
                        onDelete: { schedule.deleteSchedule(task) }
                    )
                }
                ForEach(automation.triggers) { trigger in
                    EventTriggerRow(
                        trigger: trigger,
                        connection: automation.connections.first { $0.id == trigger.connectionID },
                        selected: selectedTriggerID == trigger.id,
                        onSelect: {
                            selectedTriggerID = trigger.id
                            selectedScheduleID = nil
                        },
                        onEdit: {
                            automation.presentEditor(
                                trigger: trigger, targetSessionID: trigger.targetSessionID
                            )
                        },
                        onToggle: { automation.setTrigger(trigger, enabled: !trigger.enabled) },
                        onRearm: { automation.rearm(trigger) },
                        onDelete: { automation.deleteTrigger(trigger) }
                    )
                }
            }
        }
    }

    private var deliveryHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run History")
                .font(.locus(size: 11, weight: .bold))
                .padding(14)
            Divider()
            if let scheduleID = selectedScheduleID {
                let values = schedule.occurrencesBySchedule[scheduleID] ?? []
                if values.isEmpty {
                    ContentUnavailableView(
                        "No Time-Trigger Runs",
                        systemImage: "clock",
                        description: Text("Runs from the selected time trigger appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(values) { occurrence in
                                ScheduleOccurrenceCard(occurrence: occurrence) {
                                    if let sessionID = occurrence.sessionID,
                                       let session = app.sessions.first(where: { $0.id == sessionID }) {
                                        app.activity.activityCenterPresented = false
                                        app.resume(session)
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            } else if filteredDeliveries.isEmpty {
                ContentUnavailableView(
                    "No Triggered Runs",
                    systemImage: "tray",
                    description: Text("Durably recorded incoming events and price alerts appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(filteredDeliveries, id: \.id) { delivery in
                            EventDeliveryCard(
                                delivery: delivery,
                                onRetry: { automation.retry(delivery) },
                                onOpen: {
                                    if let sessionID = delivery.sessionID,
                                       let session = app.sessions.first(where: { $0.id == sessionID }) {
                                        app.activity.activityCenterPresented = false
                                        app.resume(session)
                                    }
                                }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.28))
    }

    private var filteredDeliveries: [EventDelivery] {
        automation.deliveries.filter {
            selectedTriggerID == nil || $0.triggerID == selectedTriggerID
        }
    }
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
    @ObservedObject var automation: EventAutomationModel
    let sessions: [SessionSummary]

    init(
        draft: EventTriggerEditorDraft,
        automation: EventAutomationModel,
        sessions: [SessionSummary]
    ) {
        _draft = State(initialValue: draft)
        self.automation = automation
        self.sessions = sessions
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
                .disabled(automation.isSaving)
            }
            .padding(18)
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
                        Text("Choose a connection").tag("")
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
                    sourceFilters
                }
                Section("What it does") {
                    Picker("Target chat", selection: $draft.targetSessionID) {
                        Text("Choose a chat").tag("")
                        ForEach(sessions.filter { !$0.isArchived }) { session in
                            Text(session.displayTitle).tag(session.id)
                        }
                    }
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(WorkMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    TextEditor(text: $draft.instruction)
                        .font(.locus(size: 10))
                        .frame(minHeight: 110)
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
