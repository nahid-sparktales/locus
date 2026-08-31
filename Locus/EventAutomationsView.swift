import AppKit
import SwiftUI

struct EventAutomationsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var automation: EventAutomationModel
    @State private var connectionSheet: ConnectorKind?
    @State private var selectedTriggerID: String?

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionsSection
                    triggersSection
                }
                .padding(20)
            }
            .frame(minWidth: 390)
            .accessibilityIdentifier("eventAutomations.center")

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
        .task { await automation.refresh(announceFailure: false) }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connections")
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
                Text("Connect Gmail, a Telegram bot, or a signed webhook before creating a trigger.")
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

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Event Triggers")
                    .font(.locus(size: 11, weight: .bold))
                Spacer()
                Button {
                    automation.presentEditor(targetSessionID: app.currentSessionID)
                } label: {
                    Label("New Trigger", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(automation.connections.isEmpty || app.currentSessionID.isEmpty)
                .accessibilityIdentifier("eventAutomations.newTrigger")
            }
            if automation.triggers.isEmpty {
                Text("A matching event starts one serialized turn in the selected existing chat.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            } else {
                ForEach(automation.triggers) { trigger in
                    EventTriggerRow(
                        trigger: trigger,
                        connection: automation.connections.first { $0.id == trigger.connectionID },
                        selected: selectedTriggerID == trigger.id,
                        onSelect: { selectedTriggerID = trigger.id },
                        onEdit: {
                            automation.presentEditor(
                                trigger: trigger, targetSessionID: trigger.targetSessionID
                            )
                        },
                        onToggle: { automation.setTrigger(trigger, enabled: !trigger.enabled) },
                        onDelete: { automation.deleteTrigger(trigger) }
                    )
                }
            }
        }
    }

    private var deliveryHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Delivery History")
                .font(.locus(size: 11, weight: .bold))
                .padding(14)
            Divider()
            let values = automation.deliveries.filter {
                selectedTriggerID == nil || $0.triggerID == selectedTriggerID
            }
            if values.isEmpty {
                ContentUnavailableView(
                    "No Matching Events",
                    systemImage: "tray",
                    description: Text("Durably recorded events and their resulting chat runs appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(values, id: \.id) { delivery in
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
}

private struct EventTriggerRow: View {
    let trigger: EventTrigger
    let connection: ConnectorConnection?
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: trigger.enabled ? "bolt.circle.fill" : "pause.circle")
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
                        Text("\(connection?.displayName ?? "Missing connection") · \(trigger.mode.title)")
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
            .buttonStyle(.plain)
            HStack(spacing: 7) {
                Button("Edit", action: onEdit)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Connect \(kind.title)", systemImage: kind.symbol)
                    .font(.locus(size: 15, weight: .bold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(kind == .webhook ? "Create" : "Connect") {
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
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(kind == .telegram && token.trimmingCharacters(in: .whitespaces).isEmpty)
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
                } else {
                    TextField("Listener port", value: $port, format: .number)
                    Toggle("Allow devices on the local network", isOn: $allowLAN)
                    TextField("Optional tunnel URL", text: $tunnelURL)
                    Text("The listener binds to localhost by default. Locus does not operate a cloud relay; configure your own tunnel if the sender is remote.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("eventAutomations.webhookSecurityNote")
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
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
                Text(draft.id == nil ? "New Event Trigger" : "Edit Event Trigger")
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
                    TextField("Name", text: $draft.name)
                    Picker("Connection", selection: $draft.connectionID) {
                        Text("Choose a connection").tag("")
                        ForEach(automation.connections.filter(\.enabled)) { connection in
                            Text(connection.displayName).tag(connection.id)
                        }
                    }
                    .onChange(of: draft.connectionID) { _, value in
                        if draft.actionConnectionIDs.isEmpty { draft.actionConnectionIDs = [value] }
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
                    ForEach(automation.connections.filter { $0.kind != .webhook }) { connection in
                        Toggle(connection.displayName, isOn: Binding(
                            get: { draft.actionConnectionIDs.contains(connection.id) },
                            set: { enabled in
                                if enabled { draft.actionConnectionIDs.append(connection.id) }
                                else { draft.actionConnectionIDs.removeAll { $0 == connection.id } }
                            }
                        ))
                    }
                    Text("The source connection is selected by default. Ask and Auto-edit still request approval for outbound actions and downloads; Full Access may proceed automatically.")
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
        if kind == .gmail {
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
