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
            LazyVStack(alignment: .leading, spacing: 16) {
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
                        Text(AgentInspectorCopy.state(run.state))
                            .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
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
                heading(event.title, subtitle: "Incoming event")
                section("Status") {
                    Text("Delivery: \(AgentInspectorCopy.deliveryState(item.deliveryState ?? delivery.state))")
                    Text("Work: \(item.executionState.map(AgentInspectorCopy.state) ?? "Not started")")
                }
                section("What started this") {
                    Text(delivery.source.title)
                    if let sender = delivery.event.actor["email"]?.string
                        ?? delivery.event.actor["name"]?.string {
                        Text("From \(sender)").foregroundStyle(LocusTheme.textSecondary)
                    }
                    Text(Date(timeIntervalSince1970: delivery.receivedAt), style: .date)
                        .foregroundStyle(LocusTheme.textSecondary)
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
                        subtitle: AgentInspectorCopy.deliveryState(item.deliveryState ?? occurrence.state))
                if let state = item.executionState {
                    Text("Work: \(AgentInspectorCopy.state(state))")
                }
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
            section("Execution history") {
                if item.executions.isEmpty {
                    Text("No execution has been recorded for this item.")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                ForEach(Array(item.executions.enumerated()), id: \.element.id) { index, execution in
                    Button {
                        let origin: AgentInspectorOrigin? = item.delivery.map { .event($0.id) }
                            ?? item.occurrence.map { .occurrence($0.id) }
                        inspector.show(.run(agent, runID: execution.runID, origin: origin))
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.executions.count == 1 ? "View work" : "Execution \(index + 1)")
                                Text(execution.state.map(AgentInspectorCopy.state) ?? "History no longer available")
                                    .font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
                                if execution.retryParentID != nil {
                                    Text("Retry").font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary)
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
        }
    }

    @ViewBuilder
    private func runDetail(agent: AgentInspectorAgent, origin: AgentInspectorOrigin?) -> some View {
        if let run = inspector.snapshot.run {
            heading(AgentInspectorCopy.runTitle(run), subtitle: AgentInspectorCopy.state(run.state))
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
            section("Time and usage") {
                if let duration = AgentInspectorCopy.duration(run) {
                    Text("Duration: \(duration)")
                } else {
                    Text("Duration: unavailable").foregroundStyle(LocusTheme.textSecondary)
                }
                if let tokens = AgentInspectorCopy.tokens(run) {
                    Text("Tokens used: \(tokens.formatted())")
                } else {
                    Text("Token usage: not reported").foregroundStyle(LocusTheme.textSecondary)
                }
                if let calls = run.usage?["model_calls"]?.integer {
                    Text("Model requests: \(calls.formatted())")
                }
            }
            DisclosureGroup("Details", isExpanded: expandedDetails) {
                VStack(alignment: .leading, spacing: 8) {
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
        }
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

    private func heading(_ title: String, subtitle: String, status: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.locus(size: 16, weight: .semibold)).textSelection(.enabled)
                .accessibilityIdentifier("agentInspector.title")
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
        .padding(12)
        .background(LocusTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .id(title)
    }

    private func issue(_ raw: String) -> some View {
        section("Needs attention") {
            Text(AgentOverview.humanizedError(raw)).textSelection(.enabled)
        }.foregroundStyle(LocusTheme.warning)
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
                Text(error).foregroundStyle(LocusTheme.textSecondary)
                Button("Try again") { Task { await inspector.refresh(backend: model.backend) } }
                    .buttonStyle(.locus()).disabled(inspector.isLoading)
            }
            .font(.locus(size: 12))
            .accessibilityIdentifier("agentInspector.loadError")
        }
    }
}

extension AgentInspectorCopy {
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
