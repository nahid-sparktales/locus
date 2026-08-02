import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorWorkflowsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                engineControls
                if model.executionEngine == .langgraph {
                    workflowControls
                    activeRun
                    reviewRequest
                    recoverableRuns
                    recentRuns
                }
            }
            .padding(14)
        }
        .background(LocusTheme.paperDeep)
        .task { await model.refreshLangGraph() }
        .accessibilityIdentifier("workflows.content")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Workflows")
                    .font(.system(size: 13, weight: .bold))
                Text(model.langGraphAvailable
                     ? "LangGraph \(model.langGraphVersion) · local and durable"
                     : "LangGraph is unavailable")
                    .font(.system(size: 9))
                    .foregroundStyle(model.langGraphAvailable ? LocusTheme.muted : LocusTheme.coral)
            }
            Spacer()
            Button {
                Task { await model.refreshLangGraph() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh workflows")
        }
    }

    private var engineControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Execution engine")
                .font(.system(size: 10, weight: .semibold))
            Picker("Execution engine", selection: Binding(
                get: { model.executionEngine },
                set: { model.setExecutionEngine($0) }
            )) {
                ForEach(ExecutionEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy || model.justChatEnabled)
            Text(model.executionEngine.detail)
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(11)
        .background(LocusTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var workflowControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.selectedMode == .plan ? "Plan workflow" : "Build workflow")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(model.selectedGraphWorkflow?.scope?.capitalized ?? "")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
            }
            Picker("Workflow", selection: Binding(
                get: { model.selectedWorkflowID },
                set: { value in
                    if let workflow = model.graphWorkflows.first(where: {
                        $0.id == value || $0.slug == value
                    }) {
                        model.selectGraphWorkflow(workflow)
                    }
                }
            )) {
                ForEach(model.compatibleGraphWorkflows) { workflow in
                    Text(workflow.name + (workflow.trusted == false ? " · Trust required" : ""))
                        .tag(workflow.id)
                }
            }
            .disabled(model.isBusy)
            if let workflow = model.selectedGraphWorkflow {
                Text(workflow.description)
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                capabilityLine(workflow)
            }
            HStack(spacing: 8) {
                Button {
                    model.graphStudioPresented = true
                } label: {
                    Label("Open Graph Studio", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                Button {
                    model.workflowRunPresented = true
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(model.isBusy || model.selectedGraphWorkflow?.isRunnable != true)
            }
        }
        .padding(11)
        .background(LocusTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var activeRun: some View {
        if model.activeGraphRunID != nil || !model.graphNodeActivities.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Active graph")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text((model.activeGraphStatus ?? "running").replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(statusColor(model.activeGraphStatus ?? "running"))
                }
                ForEach(model.graphNodeActivities) { activity in
                    DisclosureGroup {
                        if !activity.output.isEmpty {
                            Text(activity.output)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.top, 5)
                        }
                        if let error = activity.error, !error.isEmpty {
                            Text(error).font(.system(size: 9)).foregroundStyle(LocusTheme.coral)
                        }
                        if let nodeModel = activity.model {
                            HStack(spacing: 8) {
                                Label(nodeModel, systemImage: "cpu")
                                if let prompt = activity.promptTokens,
                                   let completion = activity.completionTokens {
                                    Text("\(prompt) in · \(completion) out")
                                }
                                if let limit = activity.contextLimit {
                                    Text("\(limit.formatted()) ctx")
                                }
                            }
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                            .padding(.top, 3)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(statusColor(activity.status)).frame(width: 7, height: 7)
                            Text(activity.agent).font(.system(size: 9, weight: .semibold))
                            Spacer()
                            if let duration = activity.durationMilliseconds {
                                Text("\(duration) ms").font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
                            }
                        }
                    }
                }
            }
            .padding(11)
            .background(LocusTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private var reviewRequest: some View {
        if let request = model.graphReviewRequest {
            VStack(alignment: .leading, spacing: 8) {
                Label(request.title, systemImage: "hand.raised.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LocusTheme.coral)
                if !request.message.isEmpty {
                    Text(request.message).font(.system(size: 9))
                }
                if !request.summary.isEmpty {
                    ScrollView {
                        Text(request.summary)
                            .font(.system(size: 8, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
                HStack {
                    Button("Reject") { model.answerGraphReview(approved: false) }
                    Button("Approve") { model.answerGraphReview(approved: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                }
            }
            .padding(11)
            .background(LocusTheme.coral.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.coral.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var recoverableRuns: some View {
        if !model.recoverableGraphRuns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recoverable")
                    .font(.system(size: 10, weight: .semibold))
                ForEach(model.recoverableGraphRuns) { run in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.goal).font(.system(size: 9, weight: .semibold)).lineLimit(2)
                        Text(run.status.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 8)).foregroundStyle(statusColor(run.status))
                        if !run.error.isEmpty {
                            Text(run.error).font(.system(size: 8)).foregroundStyle(LocusTheme.coral)
                        }
                        if run.status == "uncertain",
                           let effect = run.sideEffects?.first(where: { $0.status == "started" }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(effect.tool)
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                Text(effect.preview)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                    .textSelection(.enabled)
                                Text("The tool may already have changed something. Inspect the destination before retrying.")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LocusTheme.coral)
                            }
                            HStack {
                                Button("Skip effect") {
                                    Task { await model.resolveUncertainGraphRun(run, action: "skip") }
                                }
                                Button("Retry explicitly") {
                                    Task { await model.resolveUncertainGraphRun(run, action: "retry") }
                                }
                            }
                        }
                        HStack {
                            Button("Discard") { Task { await model.discardGraphRun(run) } }
                            if run.status != "uncertain" {
                                Button("Resume") { model.resumeGraphRun(run) }
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                    .padding(8)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var recentRuns: some View {
        let completed = model.graphRuns.filter { $0.status == "completed" }.prefix(5)
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent runs").font(.system(size: 10, weight: .semibold))
                ForEach(Array(completed)) { run in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(LocusTheme.success)
                        Text(run.goal).font(.system(size: 9)).lineLimit(1)
                        Spacer()
                        Text(run.mode.rawValue.capitalized)
                            .font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
                    }
                }
            }
        }
    }

    private func capabilityLine(_ workflow: GraphWorkflow) -> some View {
        let capabilities = workflow.capabilities
        return HStack(spacing: 9) {
            Label("\(capabilities?.nodeCount ?? workflow.nodes.count) nodes", systemImage: "circle.grid.3x3")
            Label("\(capabilities?.parallelWidth ?? 1) parallel", systemImage: "arrow.triangle.branch")
            if capabilities?.mayMutate == true {
                Label("May write", systemImage: "pencil")
                    .foregroundStyle(LocusTheme.coral)
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(LocusTheme.muted)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": LocusTheme.success
        case "failed", "uncertain": LocusTheme.coral
        case "waiting_permission", "waiting_review", "awaiting_credentials": LocusTheme.coral
        case "interrupted": LocusTheme.muted
        default: LocusTheme.blue
        }
    }
}

struct WorkflowRunSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var mode: WorkMode = .build
    @State private var workflowID = ""

    private var workflows: [GraphWorkflow] {
        model.graphWorkflows.filter { $0.supportedModes.contains(mode) && $0.isRunnable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Run a workflow", systemImage: "play.square.stack")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Picker("Mode", selection: $mode) {
                Text("Plan").tag(WorkMode.plan)
                Text("Build").tag(WorkMode.build)
            }
            .pickerStyle(.segmented)
            Picker("Workflow", selection: $workflowID) {
                ForEach(workflows) { workflow in
                    Text(workflow.name).tag(workflow.id)
                }
            }
            TextEditor(text: $goal)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(LocusTheme.paperDeep)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(height: 130)
                .overlay(alignment: .topLeading) {
                    if goal.isEmpty {
                        Text("What should this workflow accomplish?")
                            .font(.system(size: 10)).foregroundStyle(LocusTheme.muted)
                            .padding(12).allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Run") {
                    guard let workflow = workflows.first(where: { $0.id == workflowID }) else { return }
                    model.launchWorkflow(workflow, goal: goal, mode: mode)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workflowID.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520, height: 340)
        .background(LocusTheme.paper)
        .onAppear { chooseDefault() }
        .onChange(of: mode) { _, _ in chooseDefault() }
    }

    private func chooseDefault() {
        let preferred = mode == .plan ? model.planWorkflowID : model.buildWorkflowID
        workflowID = workflows.first(where: { $0.id == preferred || $0.slug == preferred })?.id
            ?? workflows.first?.id ?? ""
    }
}

private struct GraphPortSelection: Equatable {
    let nodeID: String
    let portID: String
    let type: String
}

struct GraphStudioView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkflowID = ""
    @State private var draft: GraphWorkflow?
    @State private var selectedNodeID: String?
    @State private var connectingSource: GraphPortSelection?
    @State private var dragOrigins: [String: GraphPosition] = [:]
    @State private var saveScope = "global"
    @State private var zoom = 1.0
    @State private var history: [GraphWorkflow] = []
    @State private var redo: [GraphWorkflow] = []
    @State private var saveInProgress = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                palette
                Divider()
                canvas
                Divider()
                inspector
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 680, idealHeight: 760)
        .background(LocusTheme.paper)
        .onAppear { selectInitialWorkflow() }
        .onChange(of: selectedWorkflowID) { _, newValue in loadWorkflow(newValue) }
        .accessibilityIdentifier("graphStudio.content")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Graph Studio", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .bold))
            Picker("Workflow", selection: $selectedWorkflowID) {
                ForEach(model.graphWorkflows) { workflow in
                    Text(workflow.name).tag(workflow.id)
                }
            }
            .frame(width: 220)
            if let draft {
                Text(draft.scope?.capitalized ?? "Draft")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(history.isEmpty)
                .help("Undo")
            Button { redoChange() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redo.isEmpty)
                .help("Redo")
            Button { exportWorkflow() } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(draft == nil)
                .help("Export JSON")
            Button { importWorkflow() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Import JSON")
            Picker("Save scope", selection: $saveScope) {
                Text("Global").tag("global")
                Text("Project").tag("project")
            }
            .frame(width: 105)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(saveInProgress || draft == nil || !validationErrors.isEmpty || model.isBusy)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Close Graph Studio")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var palette: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("NODES")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                ForEach(GraphNodeType.allCases) { type in
                    Button {
                        addNode(type)
                    } label: {
                        Label(type.title, systemImage: type.symbol)
                            .font(.system(size: 9, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 6)
                Text("Connect: select the small output dot on one node, then the input dot on another.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = connectingSource {
                    Label("\(source.nodeID).\(source.portID) · \(source.type)", systemImage: "link")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.blue)
                    Button("Cancel connection") { connectingSource = nil }
                        .font(.system(size: 8))
                }
            }
            .padding(12)
        }
        .frame(width: 155)
        .background(LocusTheme.paperDeep)
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            HStack {
                Text(validationErrors.isEmpty ? "Valid workflow" : validationErrors.joined(separator: " · "))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(validationErrors.isEmpty ? LocusTheme.success : LocusTheme.coral)
                    .lineLimit(1)
                Spacer()
                Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%").font(.system(size: 8)).frame(width: 38)
                Button { zoom = min(1.6, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        guard let draft else { return }
                        for edge in draft.edges {
                            guard let source = draft.nodes.first(where: { $0.id == edge.source }),
                                  let target = draft.nodes.first(where: { $0.id == edge.target })
                            else { continue }
                            var path = Path()
                            let start = CGPoint(
                                x: (source.position.x + 176) * zoom,
                                y: (source.position.y + portOffsetY(source, edge.sourcePort, output: true)) * zoom
                            )
                            let end = CGPoint(
                                x: target.position.x * zoom,
                                y: (target.position.y + portOffsetY(target, edge.targetPort, output: false)) * zoom
                            )
                            path.move(to: start)
                            let offset = max((end.x - start.x) * 0.45, 45)
                            path.addCurve(
                                to: end,
                                control1: CGPoint(x: start.x + offset, y: start.y),
                                control2: CGPoint(x: end.x - offset, y: end.y)
                            )
                            context.stroke(path, with: .color(LocusTheme.muted.opacity(0.55)), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 1600 * zoom, height: 1000 * zoom)
                    if let draft {
                        ForEach(draft.nodes) { node in
                            graphNode(node)
                                .position(
                                    x: (node.position.x + 88) * zoom,
                                    y: (node.position.y + nodeHeight(node) / 2) * zoom
                                )
                        }
                    }
                }
                .frame(width: 1600 * zoom, height: 1000 * zoom)
                .background(
                    Color(nsColor: .controlBackgroundColor)
                        .overlay(Canvas { context, size in
                            let spacing = 24 * zoom
                            var path = Path()
                            stride(from: 0.0, through: size.width, by: spacing).forEach { x in
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            stride(from: 0.0, through: size.height, by: spacing).forEach { y in
                                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(path, with: .color(LocusTheme.line.opacity(0.45)), lineWidth: 0.5)
                        })
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func graphNode(_ node: GraphWorkflowNode) -> some View {
        let selected = selectedNodeID == node.id
        let live = model.graphNodeActivities.first(where: { $0.nodeID == node.id })
        let rowCount = max(node.resolvedInputPorts.count, node.resolvedOutputPorts.count)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: node.type.symbol)
                Text(node.label).lineLimit(1)
                Spacer()
                if let live {
                    Circle()
                        .fill(live.status == "completed" ? LocusTheme.success : LocusTheme.blue)
                        .frame(width: 7, height: 7)
                }
            }
            .font(.system(size: 9, weight: .bold))
            Text(node.type.title)
                .font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
            ForEach(0..<rowCount, id: \.self) { index in
                portRow(node, index: index)
            }
        }
        .padding(9)
        .frame(width: 176 * zoom, height: nodeHeight(node) * zoom)
        .background(LocusTheme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? LocusTheme.blue : LocusTheme.line, lineWidth: selected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { selectedNodeID = node.id }
        .gesture(
            DragGesture()
                .onChanged { value in moveNode(node.id, translation: value.translation) }
                .onEnded { _ in dragOrigins[node.id] = nil }
        )
    }

    private func portRow(_ node: GraphWorkflowNode, index: Int) -> some View {
        let inputs = node.resolvedInputPorts
        let outputs = node.resolvedOutputPorts
        return HStack(spacing: 4) {
            if inputs.indices.contains(index) {
                let port = inputs[index]
                Button {
                    connect(to: node.id, port: port)
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(canConnect(to: node.id, port: port) ? LocusTheme.blue : LocusTheme.muted)
                            .frame(width: 8, height: 8)
                        Text(port.id)
                            .font(.system(size: 7, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Input \(port.id) · \(port.type)\(port.multiple == true ? " · multiple" : "")")
            } else {
                Spacer().frame(width: 48)
            }
            Spacer(minLength: 4)
            if outputs.indices.contains(index) {
                let port = outputs[index]
                Button {
                    connectingSource = GraphPortSelection(nodeID: node.id, portID: port.id, type: port.type)
                } label: {
                    HStack(spacing: 3) {
                        Text(port.id)
                            .font(.system(size: 7, design: .monospaced))
                            .lineLimit(1)
                        Circle().fill(LocusTheme.blue).frame(width: 8, height: 8)
                    }
                }
                .buttonStyle(.plain)
                .help("Output \(port.id) · \(port.type)")
            } else {
                Spacer().frame(width: 48)
            }
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node = selectedNodeBinding {
                    nodeEditor(node)
                } else if let workflow = workflowBinding {
                    workflowEditor(workflow)
                } else {
                    Text("Select a workflow or node")
                        .font(.system(size: 10)).foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(13)
        }
        .frame(width: 270)
        .background(LocusTheme.paperDeep)
    }

    private func workflowEditor(_ workflow: Binding<GraphWorkflow>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKFLOW").font(.system(size: 8, weight: .bold)).foregroundStyle(LocusTheme.muted)
            TextField("Name", text: workflow.name)
            TextField("Slug", text: workflow.slug)
            TextField("Description", text: workflow.description, axis: .vertical)
            Stepper("Max steps: \(workflow.wrappedValue.settings.maxSteps)", value: workflow.settings.maxSteps, in: 1...200)
            Picker("On node failure", selection: workflow.settings.failurePolicy) {
                Text("Stop run").tag("fail")
                Text("Continue branches").tag("continue")
            }
            if !workflow.wrappedValue.edges.isEmpty {
                Divider()
                Text("CONNECTIONS")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                ForEach(workflow.wrappedValue.edges) { edge in
                    HStack(spacing: 5) {
                        Text("\(edge.source).\(edge.sourcePort) → \(edge.target).\(edge.targetPort)")
                            .font(.system(size: 7, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) { removeEdge(edge.id) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if workflow.wrappedValue.scope == "project", workflow.wrappedValue.trusted == false {
                Divider()
                Label("Project workflow changed", systemImage: "exclamationmark.shield")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(LocusTheme.coral)
                Text("Review its prompts, models, tools, mutation access, and parallel branches before trusting this digest.")
                    .font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
                if let diff = workflow.wrappedValue.capabilityDiff {
                    capabilityDiffView(diff)
                }
                Button("Trust current digest") {
                    Task { await model.trustGraphWorkflow(workflow.wrappedValue) }
                }
            }
            Divider()
            HStack {
                Button("Duplicate") { Task { await model.duplicateGraphWorkflow(workflow.wrappedValue) } }
                if workflow.wrappedValue.scope != "builtin" {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.deleteGraphWorkflow(workflow.wrappedValue)
                            selectInitialWorkflow()
                        }
                    }
                }
            }
        }
        .font(.system(size: 9))
    }

    private func capabilityDiffView(_ diff: GraphWorkflowCapabilityDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if diff.firstTrust == true {
                Label("First trust: all listed capabilities are new", systemImage: "plus.circle")
            }
            if diff.promptsChanged == true {
                Label("Node prompts changed", systemImage: "text.quote")
            }
            changeLine("Tools", added: diff.toolsAdded, removed: diff.toolsRemoved)
            changeLine("Models", added: diff.modelsAdded, removed: diff.modelsRemoved)
            changeLine(
                "Provider accounts",
                added: diff.providerAccountsAdded,
                removed: diff.providerAccountsRemoved
            )
            if diff.mutationBefore != diff.mutationAfter {
                Label(
                    "Mutation access: \(diff.mutationBefore == true ? "allowed" : "none") → \(diff.mutationAfter == true ? "allowed" : "none")",
                    systemImage: "pencil.and.outline"
                )
                .foregroundStyle(diff.mutationAfter == true ? LocusTheme.coral : LocusTheme.success)
            }
            if diff.parallelWidthBefore != diff.parallelWidthAfter {
                Label(
                    "Parallel fan-out: \(diff.parallelWidthBefore ?? 0) → \(diff.parallelWidthAfter ?? 0)",
                    systemImage: "arrow.triangle.branch"
                )
            }
            if diff.changed == false {
                Label("No capability expansion; file content still changed", systemImage: "equal.circle")
            }
        }
        .font(.system(size: 8))
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.coral.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func changeLine(_ label: String, added: [String]?, removed: [String]?) -> some View {
        if !(added ?? []).isEmpty {
            Label("\(label) added: \((added ?? []).joined(separator: ", "))", systemImage: "plus")
                .foregroundStyle(LocusTheme.coral)
        }
        if !(removed ?? []).isEmpty {
            Label("\(label) removed: \((removed ?? []).joined(separator: ", "))", systemImage: "minus")
                .foregroundStyle(LocusTheme.success)
        }
    }

    private func nodeEditor(_ node: Binding<GraphWorkflowNode>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(node.wrappedValue.type.title, systemImage: node.wrappedValue.type.symbol)
                    .font(.system(size: 10, weight: .bold))
                Spacer()
                Button(role: .destructive) { removeNode(node.wrappedValue.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            TextField("Label", text: node.label)
            if [.memory, .model, .supervisor, .agent, .router, .join, .final].contains(node.wrappedValue.type) {
                Stepper(
                    "Retries: \(node.wrappedValue.config.retryCount ?? 0)",
                    value: Binding(
                        get: { node.wrappedValue.config.retryCount ?? 0 },
                        set: { node.wrappedValue.config.retryCount = $0 == 0 ? nil : $0 }
                    ),
                    in: 0...2
                )
                .help("Only model and read-only node failures are retried. Mutations are never retried automatically.")
            }
            if [.model, .supervisor, .agent, .approval, .final].contains(node.wrappedValue.type) {
                Text("Prompt").font(.system(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.muted)
                TextEditor(text: Binding(
                    get: { node.wrappedValue.config.prompt ?? "" },
                    set: { node.wrappedValue.config.prompt = $0 }
                ))
                .font(.system(size: 9))
                .frame(height: 130)
                .padding(5)
                .background(LocusTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if [.model, .supervisor, .agent, .final].contains(node.wrappedValue.type) {
                Divider()
                Text("Model").font(.system(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.muted)
                Picker("Account", selection: Binding(
                    get: { node.wrappedValue.config.modelBinding?.accountID ?? "" },
                    set: { accountID in
                        var binding = node.wrappedValue.config.modelBinding ?? GraphModelBinding()
                        binding.accountID = accountID.isEmpty ? nil : accountID
                        binding.displayHint = model.providerAccounts.first(where: {
                            $0.id.uuidString == accountID
                        })?.displayName
                        node.wrappedValue.config.modelBinding = binding
                    }
                )) {
                    Text("Inherit session model").tag("")
                    ForEach(model.providerAccounts) { account in
                        Text(account.displayName).tag(account.id.uuidString)
                    }
                }
                TextField("Model override", text: Binding(
                    get: { node.wrappedValue.config.modelBinding?.model ?? "" },
                    set: { value in
                        var binding = node.wrappedValue.config.modelBinding ?? GraphModelBinding()
                        binding.model = value.isEmpty ? nil : value
                        node.wrappedValue.config.modelBinding = binding
                    }
                ))
            }
            if [.agent, .toolSet].contains(node.wrappedValue.type) {
                Divider()
                Text("Tools (qualified names, one per line)")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.muted)
                TextEditor(text: Binding(
                    get: { (node.wrappedValue.config.tools ?? []).joined(separator: "\n") },
                    set: { text in
                        node.wrappedValue.config.tools = text
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .font(.system(size: 9, design: .monospaced))
                .frame(height: 100)
                .padding(5)
                .background(LocusTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if node.wrappedValue.type == .router {
                routerEditor(node)
            }
            Divider()
            Text("PORTS")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
            Text(portSummary(node.wrappedValue))
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .textSelection(.enabled)
        }
    }

    private func routerEditor(_ node: Binding<GraphWorkflowNode>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack {
                Text("SAFE ROUTES")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Button {
                    var rules = node.wrappedValue.config.rules ?? []
                    let targets = outgoingTargets(from: node.wrappedValue.id)
                    rules.append(GraphRouteRule(
                        operation: "contains",
                        value: "",
                        target: targets.first ?? ""
                    ))
                    node.wrappedValue.config.rules = rules
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }
            if (node.wrappedValue.config.rules ?? []).isEmpty {
                Text("Connect this Router to its destinations, then add equals, contains, exists, success, or failure rules.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            ForEach(Array((node.wrappedValue.config.rules ?? []).indices), id: \.self) { index in
                if let rule = routerRuleBinding(node, index: index) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Picker("Condition", selection: rule.operation) {
                                Text("Equals").tag("equals")
                                Text("Contains").tag("contains")
                                Text("Exists").tag("exists")
                                Text("Success").tag("success")
                                Text("Failure").tag("failure")
                            }
                            .labelsHidden()
                            Button(role: .destructive) {
                                node.wrappedValue.config.rules?.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("State path", text: rule.path)
                        if !["exists", "success", "failure"].contains(rule.wrappedValue.operation) {
                            TextField("Value", text: rule.value)
                        }
                        Picker("Destination", selection: rule.target) {
                            Text("Choose destination").tag("")
                            ForEach(outgoingTargets(from: node.wrappedValue.id), id: \.self) { target in
                                Text(target).tag(target)
                            }
                        }
                    }
                    .padding(7)
                    .background(LocusTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var workflowBinding: Binding<GraphWorkflow>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft! }, set: { draft = $0 })
    }

    private func routerRuleBinding(
        _ node: Binding<GraphWorkflowNode>,
        index: Int
    ) -> Binding<GraphRouteRule>? {
        guard (node.wrappedValue.config.rules ?? []).indices.contains(index) else { return nil }
        return Binding(
            get: { node.wrappedValue.config.rules![index] },
            set: { node.wrappedValue.config.rules![index] = $0 }
        )
    }

    private func outgoingTargets(from nodeID: String) -> [String] {
        Array(Set((draft?.edges ?? []).filter { $0.source == nodeID }.map(\.target))).sorted()
    }

    private func portSummary(_ node: GraphWorkflowNode) -> String {
        let inputs = node.resolvedInputPorts.map {
            "in.\($0.id):\($0.type)\($0.multiple == true ? "[]" : "")"
        }
        let outputs = node.resolvedOutputPorts.map { "out.\($0.id):\($0.type)" }
        return (inputs + outputs).joined(separator: "\n")
    }

    private var selectedNodeBinding: Binding<GraphWorkflowNode>? {
        guard let selectedNodeID,
              let index = draft?.nodes.firstIndex(where: { $0.id == selectedNodeID })
        else { return nil }
        return Binding(
            get: { draft!.nodes[index] },
            set: { draft!.nodes[index] = $0 }
        )
    }

    private var validationErrors: [String] {
        guard let draft else { return ["No workflow selected"] }
        var errors: [String] = []
        if draft.nodes.filter({ $0.type == .input }).count != 1 { errors.append("Exactly one Input is required") }
        if !draft.nodes.contains(where: { $0.type == .final }) { errors.append("A Final Answer is required") }
        if draft.nodes.count > 64 { errors.append("Maximum 64 nodes") }
        if draft.edges.count > 256 { errors.append("Maximum 256 edges") }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Name is required") }
        for edge in draft.edges {
            guard let source = draft.nodes.first(where: { $0.id == edge.source }),
                  let target = draft.nodes.first(where: { $0.id == edge.target }),
                  let sourcePort = source.resolvedOutputPorts.first(where: { $0.id == edge.sourcePort }),
                  let targetPort = target.resolvedInputPorts.first(where: { $0.id == edge.targetPort })
            else {
                errors.append("A connection references a missing node or port")
                continue
            }
            if sourcePort.type != "any", targetPort.type != "any", sourcePort.type != targetPort.type {
                errors.append("Incompatible connection \(source.id) → \(target.id)")
            }
        }
        return errors
    }

    private func selectInitialWorkflow() {
        let preferred = model.selectedGraphWorkflow?.id
            ?? model.graphWorkflows.first?.id
            ?? ""
        selectedWorkflowID = preferred
        loadWorkflow(preferred)
    }

    private func loadWorkflow(_ id: String) {
        guard let workflow = model.graphWorkflows.first(where: { $0.id == id }) else { return }
        draft = workflow
        saveScope = workflow.scope == "project" ? "project" : "global"
        selectedNodeID = nil
        connectingSource = nil
        dragOrigins = [:]
        history = []
        redo = []
    }

    private func snapshot() {
        guard let draft else { return }
        if history.last != draft { history.append(draft) }
        history = Array(history.suffix(50))
        redo = []
    }

    private func undo() {
        guard let previous = history.popLast(), let current = draft else { return }
        redo.append(current)
        draft = previous
    }

    private func redoChange() {
        guard let next = redo.popLast(), let current = draft else { return }
        history.append(current)
        draft = next
    }

    private func addNode(_ type: GraphNodeType) {
        guard draft != nil else { return }
        snapshot()
        let id = uniqueNodeID(type.rawValue)
        draft!.nodes.append(GraphWorkflowNode(
            id: id,
            type: type,
            label: type.title,
            position: GraphPosition(x: 260 + Double(draft!.nodes.count % 5) * 180, y: 100 + Double(draft!.nodes.count / 5) * 120),
            config: GraphNodeConfiguration(),
            inputPorts: type.defaultInputPorts,
            outputPorts: type.defaultOutputPorts
        ))
        selectedNodeID = id
    }

    private func uniqueNodeID(_ base: String) -> String {
        let existing = Set(draft?.nodes.map(\.id) ?? [])
        if !existing.contains(base) { return base }
        for number in 2...999 where !existing.contains("\(base)-\(number)") {
            return "\(base)-\(number)"
        }
        return UUID().uuidString
    }

    private func removeNode(_ id: String) {
        snapshot()
        draft?.nodes.removeAll { $0.id == id }
        draft?.edges.removeAll { $0.source == id || $0.target == id }
        selectedNodeID = nil
    }

    private func removeEdge(_ id: String) {
        snapshot()
        draft?.edges.removeAll { $0.id == id }
    }

    private func moveNode(_ id: String, translation: CGSize) {
        guard let index = draft?.nodes.firstIndex(where: { $0.id == id }) else { return }
        if dragOrigins[id] == nil {
            snapshot()
            dragOrigins[id] = draft!.nodes[index].position
        }
        guard let origin = dragOrigins[id] else { return }
        draft!.nodes[index].position.x = max(0, origin.x + translation.width / zoom)
        draft!.nodes[index].position.y = max(0, origin.y + translation.height / zoom)
    }

    private func connect(to target: String, port: GraphPort) {
        guard let source = connectingSource, source.nodeID != target, draft != nil else { return }
        guard canConnect(to: target, port: port) else {
            model.graphErrorMessage = "\(source.type) cannot connect to \(port.type). Choose a compatible typed port."
            return
        }
        if port.multiple != true,
           draft!.edges.contains(where: { $0.target == target && $0.targetPort == port.id }) {
            model.graphErrorMessage = "\(target).\(port.id) accepts one connection. Remove its existing edge first."
            return
        }
        snapshot()
        let base = "\(source.nodeID)-\(source.portID)-\(target)-\(port.id)"
        let id = draft!.edges.contains(where: { $0.id == base }) ? "\(base)-\(UUID().uuidString.prefix(6))" : base
        if !draft!.edges.contains(where: {
            $0.source == source.nodeID && $0.sourcePort == source.portID
                && $0.target == target && $0.targetPort == port.id
        }) {
            draft!.edges.append(GraphWorkflowEdge(
                id: id,
                source: source.nodeID,
                sourcePort: source.portID,
                target: target,
                targetPort: port.id
            ))
        }
        connectingSource = nil
    }

    private func canConnect(to target: String, port: GraphPort) -> Bool {
        guard let source = connectingSource else { return false }
        guard source.nodeID != target else { return false }
        return source.type == "any" || port.type == "any" || source.type == port.type
    }

    private func nodeHeight(_ node: GraphWorkflowNode) -> Double {
        let rows = max(node.resolvedInputPorts.count, node.resolvedOutputPorts.count)
        return max(76, 48 + Double(rows) * 18)
    }

    private func portOffsetY(_ node: GraphWorkflowNode, _ portID: String, output: Bool) -> Double {
        let ports = output ? node.resolvedOutputPorts : node.resolvedInputPorts
        let index = ports.firstIndex(where: { $0.id == portID }) ?? 0
        return 50 + Double(index) * 18
    }

    private func save() {
        guard var workflow = draft else { return }
        saveInProgress = true
        workflow.revision += workflow.scope == "builtin" ? 0 : 1
        Task {
            let saved = await model.saveGraphWorkflow(workflow, scope: saveScope)
            saveInProgress = false
            if saved {
                draft = model.graphWorkflows.first(where: { $0.slug == workflow.slug }) ?? workflow
            }
        }
    }

    private func exportWorkflow() {
        guard let draft else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(draft.slug).json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder.pretty.encode(draft)
        else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            model.graphErrorMessage = error.localizedDescription
        }
    }

    private func importWorkflow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              var imported = try? JSONDecoder().decode(GraphWorkflow.self, from: data)
        else {
            model.graphErrorMessage = "The selected file is not a valid Locus workflow."
            return
        }
        imported.id = UUID().uuidString
        imported.scope = nil
        imported.path = nil
        imported.digest = nil
        imported.trusted = true
        imported.revision = 1
        draft = imported
        selectedWorkflowID = imported.id
        selectedNodeID = nil
        history = []
        redo = []
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
