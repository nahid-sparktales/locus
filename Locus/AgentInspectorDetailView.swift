import SwiftUI

struct MemoryInspectorButton: View {
    let runID: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label("Memory", systemImage: "brain") }
            .buttonStyle(.locus()).help("Inspect memory submitted for this turn")
            .accessibilityIdentifier("memory.inspect.\(runID)")
            .sheet(isPresented: $showing) { MemorySubmissionInspector(runID: runID) }
    }
}

struct MemoryLearningButton: View {
    @State private var showing = false
    var body: some View {
        Button("Review learning for the current chat agent") { showing = true }
            .sheet(isPresented: $showing) { MemoryLearningPanel() }
    }
}

struct MemorySemanticSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedModel = ""
    @State private var host = "http://127.0.0.1:11434"
    @State private var installed: [String] = []
    @State private var message = ""
    @State private var busy = false
    private struct Settings: Decodable {
        let model: String
        let host: String
        let models: [String]
        let error: String?
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional local semantic memory search").font(.headline)
            Text("Keyword search is the default. Select an already installed Ollama embedding model; Locus never downloads a model automatically. Unavailable semantic search falls back to keywords.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Local Ollama address", text: $host).textFieldStyle(.roundedBorder)
            Picker("Embedding model", selection: $selectedModel) {
                Text("Disabled · keyword search").tag("")
                ForEach(installed, id: \.self) { Text($0).tag($0) }
                if !selectedModel.isEmpty && !installed.contains(selectedModel) {
                    Text(selectedModel + " (unavailable)").tag(selectedModel)
                }
            }
            HStack {
                Button("Refresh installed models") { Task { await load(useSaved: false) } }
                Button("Save memory search settings") { Task { await save() } }
                    .disabled(!selectedModel.isEmpty && !installed.contains(selectedModel))
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy || model.isBusy)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task { await load(useSaved: true) }
    }
    private func load(useSaved: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.conversationBackend.get("/api/memory/semantic-settings",
                query: useSaved ? [] : [URLQueryItem(name: "host", value: host)], as: Settings.self)
            guard !Task.isCancelled else { return }
            installed = result.models
            if useSaved { selectedModel = result.model; host = result.host }
            message = result.error ?? ""
        } catch { message = error.localizedDescription }
    }
    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let _: [String: JSONValue] = try await model.conversationBackend.post("/api/memory/semantic-settings",
                body: ["model": selectedModel, "host": host], as: [String: JSONValue].self)
            message = selectedModel.isEmpty ? "Memory uses keyword retrieval." : "Local semantic retrieval selected. Keyword fallback remains available."
        } catch { message = error.localizedDescription }
    }
}

private struct MemoryLearningPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Episode] = []
    @State private var procedures: [Procedure] = []
    @State private var suiteReviews: [SuiteReview] = []
    @State private var selectedEpisodes: Set<String> = []
    @State private var name = ""
    @State private var purpose = ""
    @State private var applicability = ""
    @State private var steps = ""
    @State private var negativeCases = ""
    @State private var visibility = "agent"
    @State private var selectedProcedure = ""
    @State private var suiteID = ""
    @State private var negativeIDs: Set<String> = []
    @State private var reviewed = false
    @State private var busy = false
    @State private var message = ""
    @State private var transport: BackendService?

    private struct Episode: Decodable, Identifiable {
        let episode_id: String
        let objective: String
        let outcome: String
        let outcome_basis: String
        var id: String { episode_id }
    }
    private struct Draft: Decodable {
        let name: String
        let purpose: String
        let applicability: String
        let steps: [String]
        let negative_cases: [String]
    }
    private struct Procedure: Decodable, Identifiable {
        let procedure_id: String
        let version: Int
        let state: String
        let draft: Draft
        let independent_evidence: Int
        let safety_findings: [String]
        var id: String { procedure_id }
    }
    private struct Episodes: Decodable { let episodes: [Episode] }
    private struct Procedures: Decodable { let procedures: [Procedure] }
    private struct SuiteReview: Decodable { let suite: EvaluationSuite; let fingerprint: String }
    private struct Suites: Decodable { let suites: [SuiteReview] }
    private var suites: [EvaluationSuite] { suiteReviews.map(\.suite) }
    private var procedure: Procedure? { procedures.first { $0.id == selectedProcedure } }
    private var selectedSuite: EvaluationSuite? { suites.first { $0.id == suiteID } }
    private var selectedSuiteReview: SuiteReview? { suiteReviews.first { $0.suite.id == suiteID } }
    private var backend: BackendService { transport ?? model.conversationBackend }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Verified learning").font(.title2); Spacer(); Button("Refresh") { Task { await load() } }; Button("Done") { dismiss() } }
            Text("Evidence for the current chat agent. An assistant's claim of success is never a passing check. Approved procedures are not installed or executed automatically.")
                .font(.callout).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            if busy { ProgressView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    episodeList
                    DisclosureGroup("Nominate a reusable procedure") { nominationForm }
                    Divider()
                    procedureReview
                }.padding(.vertical, 6)
            }
        }.padding(22).frame(minWidth: 650, minHeight: 620).task { await load() }
    }
    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task episodes").font(.headline)
            if episodes.isEmpty { Text("No retained episodes for this agent.").foregroundStyle(.secondary) }
            ForEach(episodes) { episode in
                Toggle(isOn: Binding(get: { selectedEpisodes.contains(episode.id) }, set: {
                    if $0 { selectedEpisodes.insert(episode.id) } else { selectedEpisodes.remove(episode.id) }
                })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.objective).lineLimit(3)
                        Text(episode.outcome.replacingOccurrences(of: "_", with: " ") + " · " + episode.outcome_basis)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(episode.outcome != "verified_success")
            }
        }
    }
    private var nominationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select at least two independent verified episodes above.").font(.caption)
            TextField("Procedure name", text: $name)
            TextField("Purpose", text: $purpose)
            TextField("When this procedure applies", text: $applicability)
            TextField("Steps, one per line", text: $steps, axis: .vertical).lineLimit(3...8)
            TextField("Negative cases, one per line", text: $negativeCases, axis: .vertical).lineLimit(2...6)
            Picker("Visibility", selection: $visibility) { Text("This agent").tag("agent"); Text("Workspace").tag("workspace") }
            Button("Nominate for review") { Task { await nominate() } }
                .disabled(busy || selectedEpisodes.count < 2 || [name, purpose, applicability, steps, negativeCases].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        }.textFieldStyle(.roundedBorder).padding(.top, 8)
    }
    private var procedureReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Procedure review").font(.headline)
            Picker("Candidate", selection: $selectedProcedure) {
                Text("Select a procedure").tag("")
                ForEach(procedures) { Text($0.draft.name + " · " + $0.state).tag($0.id) }
            }.onChange(of: selectedProcedure) { _, _ in reviewed = false; negativeIDs = [] }
                .onChange(of: procedure?.version) { _, _ in reviewed = false }
            if let procedure {
                Text("Version \(procedure.version) · \(procedure.independent_evidence) independent episodes").font(.caption)
                Text(procedure.draft.purpose)
                Text("Applies when: " + procedure.draft.applicability)
                ForEach(Array(procedure.draft.steps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)") }
                ForEach(procedure.draft.negative_cases, id: \.self) { Text("Must not apply: " + $0).font(.callout) }
                ForEach(procedure.safety_findings, id: \.self) { Text($0).foregroundStyle(.orange) }
                evaluationControls(procedure)
                HStack {
                    Button("Approve this evaluated version") { Task { await action("approve", procedure, body: ["approved": true]) } }
                        .disabled(busy || procedure.state != "evaluated")
                    Button("Reject candidate") { Task { await action("reject", procedure, body: ["reason": "Rejected during human review"]) } }
                        .disabled(busy || procedure.state == "rejected")
                }
            }
        }
    }
    private func evaluationControls(_ procedure: Procedure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Existing evaluation suite", selection: $suiteID) {
                Text("Select a suite").tag("")
                ForEach(suites) { Text($0.name).tag($0.id) }
            }.onChange(of: suiteID) { _, _ in negativeIDs = []; reviewed = false }
                .onChange(of: selectedSuite) { _, _ in reviewed = false }
            if let suite = selectedSuite {
                Text(suite.description).font(.caption)
                Text("Select the suite's negative cases:").font(.caption)
                ForEach(suite.cases) { entry in
                    Toggle(entry.name, isOn: Binding(get: { negativeIDs.contains(entry.id) }, set: {
                        if $0 { negativeIDs.insert(entry.id) } else { negativeIDs.remove(entry.id) }
                    }))
                    DisclosureGroup("Review case and checks") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.prompt).font(.caption)
                            Text("\(entry.target) · \(entry.mode) · \(entry.timeoutSeconds) seconds").font(.caption).foregroundStyle(.secondary)
                            if let fixture = entry.baselineFixture {
                                Text("Workspace snapshot: " + fixture.baselineTree).font(.caption.monospaced()).textSelection(.enabled)
                            } else { Text("A fixed workspace snapshot is required.").font(.caption).foregroundStyle(.orange) }
                            ForEach(entry.assertions) { check in
                                Text(check.kind + (check.required ? " · required" : " · optional")).font(.caption.bold())
                                if !check.path.isEmpty { Text(check.path).font(.caption.monospaced()) }
                                if !check.command.isEmpty { Text(check.command).font(.caption.monospaced()).textSelection(.enabled) }
                                if let value = check.value { Text(String(describing: value)).font(.caption.monospaced()) }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Toggle("I reviewed this procedure version and the selected suite before execution", isOn: $reviewed)
            }
            Button("Approve suite and evaluate in disposable worktrees") { Task { await evaluate(procedure) } }
                .disabled(busy || !reviewed || selectedSuiteReview?.fingerprint.isEmpty != false || negativeIDs.isEmpty || procedure.state != "candidate")
        }
    }
    private func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private func load() async {
        busy = true
        defer { busy = false }
        do {
            if transport == nil { transport = model.conversationBackend }
            async let e = backend.get("/api/memory/episodes", as: Episodes.self)
            async let p = backend.get("/api/memory/procedures", as: Procedures.self)
            episodes = try await e.episodes; procedures = try await p.procedures
            suiteReviews = try await backend.get("/api/memory/procedure-evaluation-suites", as: Suites.self).suites
        } catch { message = error.localizedDescription }
    }
    private func nominate() async {
        busy = true
        do {
            let _: [String: JSONValue] = try await backend.post("/api/memory/procedures/nominate", body: [
                "name": name, "purpose": purpose, "applicability": applicability, "steps": lines(steps),
                "negative_cases": lines(negativeCases), "evidence_episode_ids": Array(selectedEpisodes).sorted(),
                "visibility": visibility], as: [String: JSONValue].self)
            message = "Procedure nominated. Review and evaluate it before approval."
            await load()
        } catch { message = error.localizedDescription }
        busy = false
    }
    private func action(_ verb: String, _ procedure: Procedure, body: [String: Any]) async {
        busy = true
        do {
            var payload = body; payload["expected_version"] = procedure.version
            let _: [String: JSONValue] = try await backend.post("/api/memory/procedures/\(procedure.id)/\(verb)", body: payload, as: [String: JSONValue].self)
            message = verb == "approve" ? "Procedure approved; it has not been installed or executed." : "Procedure updated."
            await load()
        } catch { message = error.localizedDescription }
        busy = false
    }
    private func evaluate(_ procedure: Procedure) async {
        guard reviewed, let snapshot = selectedSuiteReview else {
            message = "Refresh and review the selected suite before execution."
            return
        }
        busy = true
        do {
            let _: [String: JSONValue] = try await backend.post("/api/memory/procedures/\(procedure.id)/evaluation-approval", body: [
                "approved": true, "expected_version": procedure.version, "suite_id": snapshot.suite.id,
                "expected_suite_fingerprint": snapshot.fingerprint,
                "negative_case_ids": Array(negativeIDs).sorted()], as: [String: JSONValue].self)
            let _: [String: JSONValue] = try await backend.post("/api/memory/procedures/\(procedure.id)/evaluate",
                body: ["expected_version": procedure.version], as: [String: JSONValue].self)
            message = "Evaluation queued. Refresh after it finishes to review the outcome."
            reviewed = false
        } catch { message = error.localizedDescription }
        busy = false
    }
}

private struct MemorySubmissionInspector: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let runID: String
    @State private var submissions: [Submission] = []
    @State private var helpers: [Helper] = []
    @State private var detail: Explanation?
    @State private var error = ""
    @State private var loading = true

    private struct Submission: Decodable, Identifiable {
        let submission_id: String
        let agent_id: String
        let attempt_id: String
        let turn_id: String
        let state: String
        let reason: String
        let revalidated: Bool?
        var id: String { submission_id }
        var label: String { state == "submitted" ? "Submitted to model" : state.capitalized }
    }
    private struct Helper: Decodable, Identifiable {
        let attempt_id: String
        let agent_id: String
        var id: String { attempt_id }
    }
    private struct Listing: Decodable { let submissions: [Submission]; let helpers: [Helper] }
    private struct MemorySaveResponse: Decodable { let status: String }
    private struct Item: Decodable, Identifiable {
        let record_id: String
        let scope: [String: String]
        let reasons: [String]?
        let reason: String?
        let compiled_revision: Int?
        let current_revision: Int?
        let changed_since: Bool?
        let current_title: String?
        let current_content: String?
        let tokens: Int?
        var id: String { record_id }
        var scopeLabel: String { scope.isEmpty ? "Personal" : scope.keys.sorted().map { "\($0): \(scope[$0] ?? "")" }.joined(separator: ", ") }
    }
    private struct Context: Decodable {
        struct Changes: Decodable { let added: [String]; let removed: [String]; let revised: [String]; let unavailable_before: Int }
        let items: [Item]
        let omissions: [Item]
        let token_count: Int?
        let token_allowance: Int
        let unavailable_items: Int
        let partial_reasons: [String]
        let revalidation_changes: Changes?
    }
    private struct Explanation: Decodable { let submission: Submission; let context: Context? }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Memory for this turn").font(.title2); Spacer(); Button("Done") { dismiss() } }
            Text("Submitted to model records delivery, not proof of use. Current content is shown only while you still have access.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !loading && submissions.isEmpty { Text("No retained memory submissions for this run.") }
                    ForEach(submissions) { submission in
                        Button { Task { await inspect(submission) } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(submission.agent_id) · \(submission.label)")
                                Text("Turn \(submission.turn_id.prefix(8)) · Attempt \(submission.attempt_id.prefix(8))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.locus())
                    }
                    if let detail {
                        Divider()
                        Text("\(detail.submission.agent_id) · \(detail.submission.label)").font(.headline)
                        if detail.submission.revalidated == true {
                            Text("The selection changed during final revalidation before the model call.").font(.caption)
                        }
                        if let context = detail.context {
                            if let changes = context.revalidation_changes {
                                Text("Revalidation: \(changes.added.count) added · \(changes.removed.count) removed · \(changes.revised.count) revised · \(changes.unavailable_before) previous records unavailable")
                                    .font(.caption)
                            }
                            Text("\(context.token_count.map(String.init) ?? "Unavailable") / \(context.token_allowance) tokens")
                            Text("Selected records").font(.headline)
                            ForEach(context.items) { item in itemView(item) }
                            if !context.omissions.isEmpty {
                                Text("Excluded records").font(.headline)
                                ForEach(context.omissions) { item in itemView(item) }
                            }
                            if context.unavailable_items > 0 { Text("\(context.unavailable_items) records are deleted or no longer accessible.") }
                            ForEach(context.partial_reasons, id: \.self) { Text($0).font(.caption) }
                        } else { Text(detail.submission.reason.replacingOccurrences(of: "_", with: " ")) }
                    }
                    if !helpers.isEmpty {
                        Divider()
                        Text("Helper discoveries").font(.headline)
                        Text("Discoveries follow this agent's automatic saving setting. Suggestions that need review appear in the Memory Inbox.").font(.caption)
                        ForEach(helpers) { helper in
                            Button("Remember discovery · \(helper.agent_id)") { Task { await propose(helper) } }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(22).frame(minWidth: 600, minHeight: 520).task(id: runID) { await load() }
    }

    private func itemView(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.current_title ?? item.record_id).font(.subheadline.bold())
            Text(item.scopeLabel).font(.caption).foregroundStyle(.secondary)
            Text((item.reasons ?? [item.reason ?? "not evaluated"]).joined(separator: ", ").replacingOccurrences(of: "_", with: " "))
                .font(.caption)
            if item.changed_since == true { Text("Changed since submission: revision \(item.compiled_revision ?? 0) → \(item.current_revision ?? 0)").font(.caption) }
            if let content = item.current_content { Text(content).font(.callout) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    private func load() async {
        do {
            let result = try await model.orchestrationBackend(for: runID).get("/api/memory/submissions",
                query: [URLQueryItem(name: "run_id", value: runID)], as: Listing.self)
            guard !Task.isCancelled else { return }
            submissions = result.submissions; helpers = result.helpers
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func inspect(_ submission: Submission) async {
        detail = nil; error = ""
        do {
            detail = try await model.orchestrationBackend(for: runID).get("/api/memory/submissions/\(submission.id)",
                query: [URLQueryItem(name: "run_id", value: runID), URLQueryItem(name: "include_content", value: "true")], as: Explanation.self)
        } catch { self.error = error.localizedDescription }
    }
    private func propose(_ helper: Helper) async {
        do {
            let result: MemorySaveResponse = try await model.orchestrationBackend(for: runID).post("/api/memory/helper-proposals",
                body: ["run_id": runID, "attempt_id": helper.attempt_id], as: MemorySaveResponse.self)
            error = result.status == "approved"
                ? "Memory saved and available for future recall."
                : "Suggestion added to the Memory Inbox for review."
        } catch { self.error = error.localizedDescription }
    }
}

/// Exact event/task/run detail. Opening this inspector does not change the
/// transcript; Open chat is a separate, explicit action.
struct AgentInspectorDetailView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
        .foregroundStyle(viewColors.ink)
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
                Text("No saved work in this chat yet.").foregroundStyle(viewColors.textSecondary)
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
                                Text(duration).font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
                            }
                        }
                        Text(Date(timeIntervalSince1970: run.createdAt), format: .dateTime)
                            .font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
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
                        Text("From \(sender)").foregroundStyle(viewColors.textSecondary)
                    }
                    Text(Date(timeIntervalSince1970: delivery.receivedAt), format: .dateTime)
                        .font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
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
                            .foregroundStyle(viewColors.textSecondary)
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
                        .foregroundStyle(viewColors.textSecondary)
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
                                    .font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
                                if let created = execution.createdAt {
                                    Text(Date(timeIntervalSince1970: created), format: .dateTime)
                                        .font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
                                }
                                if execution.retryParentID != nil {
                                    Text("Retry").font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
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
            MemoryInspectorButton(runID: run.id)
            MemoryLearningButton()
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
                        .foregroundStyle(viewColors.textSecondary)
                }
                if !work.files.isEmpty {
                    Text("Files in recent activity").font(.locus(size: 12, weight: .semibold))
                    ForEach(work.files.prefix(10)) { file in
                        Text("\(URL(fileURLWithPath: file.path).lastPathComponent) · \(file.effect)")
                            .font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
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
                }.padding(.top, 8).font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
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
                    Text("Elapsed").foregroundStyle(viewColors.textSecondary)
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
                        .font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
                        .textSelection(.enabled)
                }
                if !work.commands.isEmpty {
                    Text("Recent commands").font(.locus(size: 11, weight: .semibold))
                    ForEach(work.commands.suffix(5)) { command in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: command.ok ? "checkmark" : "exclamationmark.circle")
                                .foregroundStyle(command.ok ? viewColors.textSecondary : viewColors.warning)
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
            Text(detail).font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
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
                    .foregroundStyle(viewColors.textSecondary)
                    .accessibilityIdentifier("agentInspector.chat.state")
            }
            Text(subtitle).foregroundStyle(viewColors.textSecondary)
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
        .overlay(alignment: .top) { Rectangle().fill(viewColors.line).frame(height: 1) }
        .id(title)
    }

    private func detailFact(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(viewColors.textSecondary)
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
        .foregroundStyle(viewColors.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(viewColors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct AgentInspectorLoadStatus: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                Text(error).foregroundStyle(viewColors.textSecondary)
                if let loadedAt = inspector.loadedAt {
                    Text("Last updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.locus(size: 11)).foregroundStyle(viewColors.textSecondary)
                }
                Button(inspector.isLoading ? "Retrying…" : "Try again") { Task { await inspector.refresh(backend: model.backend) } }
                    .buttonStyle(.locus()).disabled(inspector.isLoading)
            }
            .font(.locus(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(viewColors.warning.opacity(0.07))
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
        // Ordinary chat runs are stored with an empty schedule ID.
        if run.scheduleID?.nilIfEmpty != nil { return "Scheduled work" }
        let firstLine = run.request.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Saved work" : String(firstLine.prefix(180))
    }
}

/// Each row resolves a saved version from the selected run's provenance. The
/// workspace library may contain newer versions from unrelated conversations.
struct AgentInspectorRunOutputs: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    let run: OrchestrationRun
    let workspace: String
    var hidesWhenEmpty = false
    var onOpen: ((LibraryOutput, OutputVersion) -> Void)? = nil
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
            if !hidesWhenEmpty || !loaded || failed || !rows.isEmpty {
                Text("Saved outputs").font(.locus(size: 12, weight: .semibold))
                if !loaded {
                    ProgressView("Finding outputs…").controlSize(.small)
                } else if failed {
                    Text("Saved outputs could not be loaded.")
                        .foregroundStyle(viewColors.textSecondary)
                } else if rows.isEmpty {
                    Text("No saved outputs are linked to this run.")
                        .foregroundStyle(viewColors.textSecondary)
                }
                ForEach(rows) { row in
                    Button {
                        if let onOpen { onOpen(row.item, row.version) }
                        else { model.openLibraryOutput(itemID: row.item.id, versionID: row.version.id, workspace: workspace) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.item.title).lineLimit(2)
                            Text(row.version.label).font(.locus(size: 12))
                                .foregroundStyle(viewColors.textSecondary)
                            if let reason = row.version.unavailableReason {
                                Text(reason).font(.locus(size: 12)).foregroundStyle(viewColors.textSecondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("agentInspector.output.\(row.id)")
                }
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
