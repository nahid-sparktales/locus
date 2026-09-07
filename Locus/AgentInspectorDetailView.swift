import SwiftUI

/// Exact event/task/run detail. Opening this inspector does not change the
/// transcript; Open chat is a separate, explicit action.
struct AgentInspectorDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @ObservedObject var inspector: AgentInspectorModel
    let context: AgentInspectorContext

    private var expandedDetails: Binding<Bool> {
        Binding(get: { inspector.presentation[context]?.expandedDetails ?? false },
                set: { inspector.presentation[context, default: AgentInspectorPresentation()].expandedDetails = $0 })
    }
    private var scrollAnchor: Binding<String?> {
        Binding(get: { inspector.presentation[context]?.scrollAnchor },
                set: { inspector.presentation[context, default: AgentInspectorPresentation()].scrollAnchor = $0 })
    }
    private var expandedIncomingContent: Binding<Bool> {
        Binding(get: { inspector.presentation[context]?.expandedIncomingContent ?? false },
                set: { inspector.presentation[context, default: AgentInspectorPresentation()].expandedIncomingContent = $0 })
    }

    private var reference: AgentInspectorAgent? { context.agent }
    private var definition: AgentDefinition? { reference.flatMap(model.inspectorAgentDefinition) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Button { inspector.back() } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("agentInspector.back")
                AgentInspectorLoadStatus(inspector: inspector)
                switch context {
                case .chat(let agent, let sessionID):
                    chatDetail(agent: agent, sessionID: sessionID)
                case .event(let agent, _), .occurrence(let agent, _):
                    itemDetail(agent: agent)
                case .run(let agent, _, let origin):
                    runDetail(agent: agent, origin: origin)
                case .agent, .fleet: EmptyView()
                }
            }
            .scrollTargetLayout()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .font(.locus(size: 13))
        .foregroundStyle(LocusTheme.ink)
        .accessibilityIdentifier("agentInspector.detail")
    }

    private var backLabel: String {
        if case .run(_, _, let origin) = context, let origin {
            return switch origin {
            case .chat: "Back to chat"
            case .event: "Back to event"
            case .occurrence: "Back to scheduled run"
            }
        }
        return definition?.name ?? "Back to agent"
    }

    @ViewBuilder
    private func chatDetail(agent: AgentInspectorAgent, sessionID: String) -> some View {
        if let session = model.sessionCatalog.snapshot.sessionsByID[sessionID] {
            heading(session.displayTitle,
                    subtitle: session.isAgentEventChat
                        ? "This chat receives the agent’s \(agent.kind == .schedule ? "scheduled runs" : "events")."
                        : "A side conversation with \(definition?.name ?? "this agent"). It does not receive incoming events or scheduled work.",
                    status: chatWorkState(sessionID))
            if !session.preview.isEmpty {
                section("Chat preview") {
                    Text(SessionSummary.cleanPreview(session.preview)).lineLimit(6).textSelection(.enabled)
                }
            }
            Button(sessionID == model.currentSessionID ? "Return to chat" : "Open chat") {
                openChat(sessionID)
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier("agentInspector.openChat")
            if let workspace = session.workspacePath {
                Button("View chat outputs") {
                    model.openOutputsLibrary(workspace: workspace, sessionID: sessionID)
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("agentInspector.chatOutputs")
            }
        } else {
            heading("Chat unavailable", subtitle: "Its saved execution history may still be available below.")
        }
        section("Recent work") {
            if inspector.snapshot.runs.isEmpty && !inspector.isLoading && inspector.error == nil {
                Text("No saved work in this chat yet.").foregroundStyle(LocusTheme.textSecondary)
            }
            ForEach(inspector.snapshot.runs) { run in
                Button {
                    inspector.show(.run(agent, runID: run.id, origin: .chat(sessionID)))
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AgentInspectorCopy.runTitle(run)).lineLimit(2)
                        HStack(spacing: 8) {
                            AgentRunStateLabel(rawState: run.state)
                            Spacer(minLength: 0)
                            if let duration = AgentInspectorCopy.duration(run) {
                                Text(duration).font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                            }
                        }
                        Text(Date(timeIntervalSince1970: run.createdAt), format: .dateTime)
                            .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("agentInspector.run.\(run.id)")
            }
        }
    }

    @ViewBuilder
    private func itemDetail(agent: AgentInspectorAgent) -> some View {
        if let item = inspector.snapshot.item {
            if let delivery = item.delivery {
                let event = AgentOverview.Event(delivery: delivery)
                heading(event.title, subtitle: "Incoming event · \(definition?.name ?? "Agent")",
                        rawState: item.executionState ?? AgentInspectorCopy.effectiveActivityState(deliveryState: delivery.state, runState: delivery.runState))
                section("Status") {
                    detailFact("Delivery", value: AgentInspectorCopy.deliveryState(item.deliveryState ?? delivery.state))
                    detailFact("Execution", value: item.executionState.map(AgentInspectorCopy.state) ?? "Not started")
                }
                section("What started this") {
                    Text(delivery.source.title)
                    if let sender = delivery.event.actor["email"]?.string
                        ?? delivery.event.actor["name"]?.string {
                        Text("From \(sender)").foregroundStyle(LocusTheme.textSecondary)
                    }
                    Text(Date(timeIntervalSince1970: delivery.receivedAt), format: .dateTime)
                        .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                    if !delivery.event.text.isEmpty {
                        DisclosureGroup("Incoming content · untrusted source", isExpanded: expandedIncomingContent) {
                            Text(delivery.event.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .accessibilityIdentifier("agentInspector.untrustedContent")
                    }
                }
                if let error = delivery.error?.nilIfEmpty {
                    issue(error)
                }
                if item.workflowExecutionID != nil && (event.canRetry || ["failed", "waiting_approval"].contains(item.executionState ?? "")) {
                    Button("Review workflow") {
                        if let id = item.workflowExecutionID { activity.openActivityCenter(focus: .workflow(id)) }
                    }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentInspector.reviewWorkflow")
                } else if event.canRetry {
                    Button(model.eventAutomations.retryingDeliveryIDs.contains(delivery.id)
                        ? "Retrying…" : "Retry this event") {
                        Task {
                            if await model.eventAutomations.retryDelivery(delivery.id, previousRunID: delivery.runID) {
                                await inspector.refresh(backend: model.backend)
                            }
                        }
                    }
                    .disabled(model.eventAutomations.retryingDeliveryIDs.contains(delivery.id))
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("agentInspector.retryEvent")
                }
                if let sessionID = delivery.conversationSessionID {
                    Button("Open receiving chat") { openChat(sessionID) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agentInspector.openChat")
                }
            } else if let occurrence = item.occurrence {
                heading(occurrence.trigger == "manual" ? "Requested run" : "Scheduled run",
                        subtitle: "Schedule · \(occurrence.scheduleName)",
                        rawState: item.executionState ?? occurrence.state)
                detailFact("Delivery", value: AgentInspectorCopy.deliveryState(item.deliveryState ?? occurrence.state))
                section("What started this") {
                    Text(occurrence.scheduleName)
                    Text(Date(timeIntervalSince1970: occurrence.scheduledFor), format: .dateTime)
                    if occurrence.state == "skipped" {
                        Text("This time slot passed while the earlier work was still running.")
                            .foregroundStyle(LocusTheme.textSecondary)
                    }
                }
                if let error = occurrence.error?.nilIfEmpty, occurrence.state != "skipped" { issue(error) }
                if let id = item.workflowExecutionID,
                   ["failed", "waiting_approval"].contains(item.executionState ?? "") {
                    Button("Review workflow") { activity.openActivityCenter(focus: .workflow(id)) }
                        .buttonStyle(.locus()).accessibilityIdentifier("agentInspector.reviewWorkflow")
                }
                if let sessionID = occurrence.sessionID {
                    Button("Open chat") { openChat(sessionID) }.buttonStyle(.locus())
                        .accessibilityIdentifier("agentInspector.openChat")
                }
            }
            section("Executions") {
                if item.executions.isEmpty {
                    Text("No execution has been recorded. A run appears here once this item starts work.")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                ForEach(item.executions) { execution in
                    Button {
                        let origin: AgentInspectorOrigin? = item.delivery.map { .event($0.id) }
                            ?? item.occurrence.map { .occurrence($0.id) }
                        inspector.show(.run(agent, runID: execution.runID, origin: origin))
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.executions.count == 1 ? "Inspect run" : "Attempt \(execution.attempt)")
                                Text(execution.state.map(AgentInspectorCopy.state) ?? "History no longer available")
                                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                                if let created = execution.createdAt {
                                    Text(Date(timeIntervalSince1970: created), format: .dateTime)
                                        .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                                }
                                if execution.retryParentID != nil {
                                    Text("Retry").font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                        }.padding(.vertical, 6)
                    }
                    .disabled(execution.state == nil)
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("agentInspector.execution.\(execution.runID)")
                }
            }
        } else if !inspector.isLoading && inspector.error == nil {
            missingDetail("Activity unavailable", detail: "This item may have been removed from saved history. Return to the agent to inspect other activity.")
        }
    }

    @ViewBuilder
    private func runDetail(agent: AgentInspectorAgent, origin: AgentInspectorOrigin?) -> some View {
        if let run = inspector.snapshot.run {
            heading(AgentInspectorCopy.runTitle(run),
                    subtitle: definition?.name ?? "Agent run", rawState: run.state)
            runTiming(run)
            if ["waiting_permission", "waiting_approval", "waiting_dispatch_approval", "waiting_computer"].contains(run.state) {
                section("Needs your attention") {
                    Text("Review the request before this work can continue.")
                    Button("Review request") {
                        if let id = run.manifest?["workflow_execution_id"]?.string {
                            activity.openActivityCenter(focus: .workflow(id))
                        } else { activity.openActivityCenter(focus: .run(run.id)) }
                    }
                        .buttonStyle(.locus()).accessibilityIdentifier("agentInspector.review")
                }
            }
            if let reason = run.recoveryReason?.nilIfEmpty { issue(reason) }
            let work = RunWork(events: inspector.snapshot.events)
            section(run.state == "completed" ? "Result" : "Progress") {
                if let latest = inspector.snapshot.events.last(where: {
                    ["note", "error", "task_ready", "task_applied"].contains($0.type)
                        && $0.text("summary")?.nilIfEmpty != nil
                })?.text("summary") {
                    Text(latest).textSelection(.enabled).lineLimit(8)
                } else {
                    Text(run.state == "completed"
                        ? "The work completed. Open the chat to read the response."
                        : "The latest saved state is shown above. Open the chat for the full conversation.")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                if !work.files.isEmpty {
                    Text("Files in recent activity").font(.locus(size: 12, weight: .semibold))
                    ForEach(work.files.prefix(10)) { file in
                        Text("\(URL(fileURLWithPath: file.path).lastPathComponent) · \(file.effect)")
                            .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                            .help(file.path)
                    }
                }
                if let sessionID = run.sessionID {
                    Button("Open this work in chat") {
                        if model.sessionCatalog.snapshot.sessionsByID[sessionID] != nil {
                            model.openActivityRun(run)
                        } else { model.showToast("That chat is no longer available") }
                    }
                    .buttonStyle(.locus()).accessibilityIdentifier("agentInspector.openRun")
                }
                if let workspace = run.workspaceRoot {
                    AgentInspectorRunOutputs(run: run, workspace: workspace)
                    Button("View outputs from this run") {
                        model.openOutputsLibrary(workspace: workspace, sessionID: run.sessionID, runID: run.id)
                    }
                    .buttonStyle(.locus()).accessibilityIdentifier("agentInspector.runOutputs")
                }
            }
            runActions(work)
            DisclosureGroup("Technical details & usage", isExpanded: expandedDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    if let tokens = AgentInspectorCopy.tokens(run) {
                        detailFact("Tokens used", value: tokens.formatted())
                    }
                    if let calls = run.usage?["model_calls"]?.integer {
                        detailFact("Model requests", value: calls.formatted())
                    }
                    Text("Created \(Date(timeIntervalSince1970: run.createdAt).formatted())")
                    if let admittedAt = run.admittedAt {
                        Text("Work started \(Date(timeIntervalSince1970: admittedAt).formatted())")
                    }
                    if let completedAt = run.completedAt {
                        Text("Finished \(Date(timeIntervalSince1970: completedAt).formatted())")
                    }
                    if let workspace = run.workspaceRoot { Text("Workspace: \(workspace)") }
                    Text("Run: \(run.id)").textSelection(.enabled)
                    if let parent = run.retryParentID { Text("Retry of: \(parent)").textSelection(.enabled) }
                }.padding(.top, 8).font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
            }
            .id("run-details")
            .accessibilityIdentifier("agentInspector.runDetails")
        } else if !inspector.isLoading && inspector.error == nil {
            missingDetail("Run unavailable", detail: "This execution may have been removed from saved history. Return to the agent to inspect other activity.")
        }
    }

    private func runTiming(_ run: OrchestrationRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            detailFact(run.admittedAt == nil ? "Created" : "Started", value: Date(timeIntervalSince1970: run.admittedAt ?? run.createdAt)
                .formatted(date: .abbreviated, time: .shortened))
            if let duration = AgentInspectorCopy.duration(run) {
                detailFact("Duration", value: duration)
            } else if let start = run.admittedAt, run.completedAt == nil,
                      AgentActivityState(rawState: run.state) == .running {
                HStack {
                    Text("Elapsed").foregroundStyle(LocusTheme.textSecondary)
                    Spacer()
                    Text(Date(timeIntervalSince1970: start), style: .timer).monospacedDigit()
                }
            }
        }
        .font(.locus(size: 12))
        .accessibilityIdentifier("agentInspector.runTiming")
    }

    @ViewBuilder
    private func runActions(_ work: RunWork) -> some View {
        let tools = Array(Set(inspector.snapshot.events.filter { $0.type == "tool_result" }
            .compactMap { $0.text("tool")?.nilIfEmpty })).sorted()
        if work.toolSteps > 0 {
            section("Actions taken") {
                detailFact("Tool calls", value: "\(work.toolSteps)")
                if !tools.isEmpty {
                    Text(tools.joined(separator: " · "))
                        .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                        .textSelection(.enabled)
                }
                if !work.commands.isEmpty {
                    Text("Recent commands").font(.locus(size: 11, weight: .semibold))
                    ForEach(work.commands.suffix(5)) { command in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: command.ok ? "checkmark" : "exclamationmark.circle")
                                .foregroundStyle(command.ok ? LocusTheme.textSecondary : LocusTheme.warning)
                            Text(command.summary).lineLimit(3).textSelection(.enabled)
                        }
                        .font(.locus(size: 12))
                    }
                }
            }
            .accessibilityIdentifier("agentInspector.runActions")
        }
    }

    private func missingDetail(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "clock.badge.questionmark")
                .font(.locus(size: 14, weight: .semibold))
            Text(detail).font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
        .accessibilityIdentifier("agentInspector.unavailable")
    }

    private func openChat(_ sessionID: String) {
        guard let session = model.sessionCatalog.snapshot.sessionsByID[sessionID] else {
            model.showToast("That chat is no longer available")
            return
        }
        if model.currentSessionID != sessionID { model.resume(session) }
    }

    private func chatWorkState(_ sessionID: String) -> String {
        if model.runningChatSessionIDs.contains(sessionID) { return "Working" }
        if let run = inspector.snapshot.runs.first,
            ["pending", "claiming", "queued", "dispatching", "running", "waiting_permission", "waiting_approval",
             "waiting_dispatch_approval", "waiting_computer", "paused", "interrupted", "failed"].contains(run.state) {
            return AgentInspectorCopy.state(run.state)
        }
        if inspector.loadedAt == nil { return inspector.isLoading ? "Checking status…" : "Status unavailable" }
        return "Idle"
    }

    private func heading(_ title: String, subtitle: String, status: String? = nil, rawState: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.locus(size: 16, weight: .semibold)).textSelection(.enabled)
                .accessibilityIdentifier("agentInspector.title")
            if let rawState { AgentRunStateLabel(rawState: rawState) }
            if let status {
                Text(status).font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .accessibilityIdentifier("agentInspector.chat.state")
            }
            Text(subtitle).foregroundStyle(LocusTheme.textSecondary)
                .accessibilityIdentifier("agentInspector.status")
        }
        .id("heading")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.locus(size: 12, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .id(title)
    }

    private func detailFact(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(LocusTheme.textSecondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.locus(size: 12))
        .accessibilityElement(children: .combine)
    }

    private func issue(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Needs attention", systemImage: "exclamationmark.circle")
                .font(.locus(size: 12, weight: .semibold))
            Text(AgentOverview.humanizedError(raw))
                .font(.locus(size: 12)).textSelection(.enabled)
        }
        .foregroundStyle(LocusTheme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(LocusTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct AgentInspectorLoadStatus: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var inspector: AgentInspectorModel

    var body: some View {
        if inspector.isLoading && inspector.loadedAt == nil {
            ProgressView("Loading…").controlSize(.small)
                .accessibilityIdentifier("agentInspector.loading")
        } else if let error = inspector.error {
            VStack(alignment: .leading, spacing: 8) {
                Label(inspector.loadedAt == nil ? "Couldn’t load activity" : "Activity may be out of date", systemImage: "arrow.clockwise.circle")
                    .font(.locus(size: 12, weight: .semibold))
                Text(error).foregroundStyle(LocusTheme.textSecondary)
                if let loadedAt = inspector.loadedAt {
                    Text("Last updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.locus(size: 11)).foregroundStyle(LocusTheme.textSecondary)
                }
                Button(inspector.isLoading ? "Retrying…" : "Try again") { Task { await inspector.refresh(backend: model.backend) } }
                    .buttonStyle(.locus()).disabled(inspector.isLoading)
            }
            .font(.locus(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(LocusTheme.warning.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("agentInspector.loadError")
        }
    }
}

/// Classifies persisted execution state for every activity surface. A received
/// delivery is not necessarily a completed execution, and unknown states must
/// never look like successes.
enum AgentActivityState: Equatable {
    case completed, running, waiting, attention, neutral

    init(rawState: String) {
        switch rawState {
        case "completed": self = .completed
        case "claiming", "dispatching", "planning", "running", "advancing", "awaiting_run": self = .running
        case "pending", "queued": self = .waiting
        case "failed", "interrupted", "paused", "waiting_permission", "waiting_dispatch_approval",
             "waiting_approval", "waiting_computer": self = .attention
        default: self = .neutral
        }
    }

    var color: Color {
        switch self {
        case .completed: LocusTheme.success
        case .running: LocusTheme.signalDeep
        case .waiting, .neutral: LocusTheme.textSecondary
        case .attention: LocusTheme.warning
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .attention: "exclamationmark.circle"
        case .neutral: "minus.circle"
        }
    }
}

private struct AgentRunStateLabel: View {
    let rawState: String
    private var state: AgentActivityState { AgentActivityState(rawState: rawState) }

    var body: some View {
        Label(AgentInspectorCopy.state(rawState), systemImage: state.symbol)
            .font(.locus(size: 11, weight: .medium))
            .foregroundStyle(state.color)
            .accessibilityElement(children: .combine)
    }
}

extension AgentInspectorCopy {
    static func agentStatusTitle(_ status: AgentOverview.Status, vocabulary: Vocabulary = .events,
                                 isRunning: Bool = false, sourceNeedsAttention: Bool = false) -> String {
        if isRunning { return "Running" }
        if sourceNeedsAttention || status.isWarning { return "Needs attention" }
        if status == .fired { return "Completed" }
        return status == .active ? "Ready" : status.title(for: vocabulary)
    }

    /// A receipt that failed or was cancelled cannot become successful merely
    /// because its previous linked execution finished. Successful handoffs may
    /// still have live or waiting work, so they use a reported execution state.
    static func effectiveActivityState(deliveryState: String, runState: String?) -> String {
        if ["failed", "interrupted", "cancelled", "skipped"].contains(deliveryState) {
            return deliveryState
        }
        return runState?.nilIfEmpty ?? deliveryState
    }

    static func sourceNeedsAttention(definition: AgentDefinition?, connection: ConnectorConnection?) -> Bool {
        guard let definition, definition.enabled, definition.trigger != nil else { return false }
        guard let connection else { return true }
        return !connection.enabled || connection.health.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "connected"
    }

    static func activityState(_ event: AgentOverview.Event) -> AgentActivityState {
        if let delivery = event.delivery {
            return AgentActivityState(rawState: effectiveActivityState(deliveryState: delivery.state, runState: delivery.runState))
        }
        // Schedule occurrence rows already expose their localized state title.
        // Match the same formatter instead of treating every terminal item as
        // a success. This also leaves future, unrecognized states neutral.
        for state in ["completed", "running", "claiming", "queued", "failed", "interrupted", "paused",
                      "waiting_permission", "waiting_computer", "cancelled", "skipped"]
        where Self.state(state) == event.stateTitle {
            return AgentActivityState(rawState: state)
        }
        return .neutral
    }

    static func duration(_ run: OrchestrationRun) -> String? {
        guard let start = run.admittedAt, let end = run.completedAt,
              start.isFinite, end.isFinite, end >= start else { return nil }
        let seconds = Int(end - start)
        if seconds < 1 { return "Less than a second" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min \(seconds % 60) sec" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    static func tokens(_ run: OrchestrationRun) -> Int? {
        if let total = run.usage?["metered_tokens"]?.integer { return total }
        guard let prompt = run.usage?["prompt_tokens"]?.integer,
              let completion = run.usage?["completion_tokens"]?.integer else { return nil }
        return prompt + completion
    }

    static func runTitle(_ run: OrchestrationRun) -> String {
        if run.manifest?["event_triggered"]?.boolean == true { return "Work from an incoming event" }
        if run.scheduleID != nil { return "Scheduled work" }
        let firstLine = run.request.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Saved work" : String(firstLine.prefix(180))
    }
}

/// Each row resolves a saved version from the selected run's provenance. The
/// workspace library may contain newer versions from unrelated conversations.
private struct AgentInspectorRunOutputs: View {
    @EnvironmentObject private var model: AppModel
    let run: OrchestrationRun
    let workspace: String
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var failed = false

    private struct Row: Identifiable {
        let item: LibraryOutput
        let version: OutputVersion
        var id: String { item.id + ":" + version.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved outputs").font(.locus(size: 12, weight: .semibold))
            if !loaded {
                ProgressView("Finding outputs…").controlSize(.small)
            } else if failed {
                Text("Saved outputs could not be loaded.")
                    .foregroundStyle(LocusTheme.textSecondary)
            } else if rows.isEmpty {
                Text("No saved outputs are linked to this run.")
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            ForEach(rows) { row in
                Button {
                    model.openLibraryOutput(itemID: row.item.id, versionID: row.version.id, workspace: workspace)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.item.title).lineLimit(2)
                        Text(row.version.label).font(.locus(size: 12))
                            .foregroundStyle(LocusTheme.textSecondary)
                        if let reason = row.version.unavailableReason {
                            Text(reason).font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("agentInspector.output.\(row.id)")
            }
        }
        .accessibilityIdentifier("agentInspector.savedOutputs")
        .task(id: workspace + ":" + run.id + ":" + String(run.updatedAt)) {
            rows = []; loaded = false; failed = false
            do {
                await model.outputsLibrary.flush()
                let items = try await model.outputsLibrary.store.list(workspace: workspace)
                guard !Task.isCancelled else { return }
                rows = items.flatMap { item in
                    item.versions.filter { $0.belongsTo(sessionID: nil, runID: run.id) }
                        .map { Row(item: item, version: $0) }
                }.sorted { $0.version.capturedAt > $1.version.capturedAt }
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loaded = true
        }
    }
}
