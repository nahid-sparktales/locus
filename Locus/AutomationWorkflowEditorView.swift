import SwiftUI

struct WorkflowConnectorOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct WorkflowSimulationTrace: Codable, Identifiable {
    let stepID: String
    let type: String
    let title: String
    let prompt: String?
    let mode: String?
    let explanation: String?
    let outcome: Bool?
    let needsMockOutputs: Bool?

    var id: String { stepID }

    enum CodingKeys: String, CodingKey {
        case type, title, prompt, mode, explanation, outcome
        case stepID = "step_id"
        case needsMockOutputs = "needs_mock_outputs"
    }
}

struct WorkflowSimulationResponse: Codable {
    let valid: Bool
    let complete: Bool
    let waitingForApproval: Bool?
    let trace: [WorkflowSimulationTrace]

    enum CodingKeys: String, CodingKey {
        case valid, complete, trace
        case waitingForApproval = "waiting_for_approval"
    }
}

extension AppModel {
    func simulateAutomationWorkflow(
        _ workflow: AutomationWorkflow,
        sampleEventJSON: String,
        mockOutputsJSON: String,
        allowedConnectionIDs: [String]
    ) async throws -> WorkflowSimulationResponse {
        func object(_ text: String, label: String) throws -> [String: Any] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [:] }
            guard let data = trimmed.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw NSError(
                    domain: "Locus.WorkflowSimulation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(label) must be a JSON object."]
                )
            }
            return value
        }
        guard let encoded = encodedJSONObject(workflow) else {
            throw NSError(
                domain: "Locus.WorkflowSimulation", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The workflow could not be encoded."]
            )
        }
        return try await backend.post(
            "/api/automation-workflows/simulate",
            body: [
                "workflow": encoded,
                "trigger": try object(sampleEventJSON, label: "Sample event"),
                "mock_outputs": try object(mockOutputsJSON, label: "Mock outputs"),
                "allowed_connection_ids": allowedConnectionIDs,
            ],
            as: WorkflowSimulationResponse.self
        )
    }
}

/// Shared vertical workflow editor used by both scheduled and event agents.
struct AutomationWorkflowEditorView: View {
    @Binding var workflow: AutomationWorkflow
    var connectors: [WorkflowConnectorOption] = []
    @State private var repairedStepIDs: [String] = []
    @State private var simulationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workflow")
                        .font(.locus(size: 11, weight: .bold))
                    Text("Runs from top to bottom. Branches may only point forward.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Simulate…") { simulationPresented = true }
                    .accessibilityIdentifier("workflow.simulate")
                Menu("Add Step") {
                    ForEach(AutomationWorkflowStepType.allCases) { type in
                        Button(type.title) { add(type) }
                    }
                }
                .disabled(workflow.steps.count >= 20)
                .accessibilityIdentifier("workflow.addStep")
            }
            if !repairedStepIDs.isEmpty {
                Label(
                    "A moved step pointed backward, so its affected branch target was reset.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.locus(size: 8, weight: .medium))
                .foregroundStyle(LocusTheme.warning)
                .accessibilityIdentifier("workflow.reorderWarning")
            }
            ForEach(Array(workflow.steps.indices), id: \.self) { index in
                WorkflowStepCard(
                    step: stepBinding(index),
                    index: index,
                    total: workflow.steps.count,
                    laterSteps: Array(workflow.steps.dropFirst(index + 1)),
                    connectors: connectors,
                    moveUp: { move(index, by: -1) },
                    moveDown: { move(index, by: 1) },
                    remove: { remove(index) }
                )
            }
        }
        .sheet(isPresented: $simulationPresented) {
            WorkflowSimulationSheet(
                workflow: workflow,
                allowedConnectionIDs: connectors.map(\.id)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automation workflow, \(workflow.steps.count) steps")
    }

    private func stepBinding(_ index: Int) -> Binding<AutomationWorkflowStep> {
        Binding(
            get: { workflow.steps[index] },
            set: { workflow.steps[index] = $0 }
        )
    }

    private func add(_ type: AutomationWorkflowStepType) {
        guard workflow.steps.count < 20 else { return }
        let step: AutomationWorkflowStep = switch type {
        case .agent: .agent()
        case .condition: .condition()
        case .approval: .approval()
        }
        if let last = workflow.steps.indices.last {
            switch workflow.steps[last].type {
            case .agent:
                if workflow.steps[last].nextStepID == nil || workflow.steps[last].nextStepID == "finish" {
                    workflow.steps[last].nextStepID = step.id
                }
            case .condition:
                if workflow.steps[last].trueStepID == nil || workflow.steps[last].trueStepID == "finish" {
                    workflow.steps[last].trueStepID = step.id
                }
            case .approval:
                if workflow.steps[last].approveStepID == nil || workflow.steps[last].approveStepID == "finish" {
                    workflow.steps[last].approveStepID = step.id
                }
            }
        }
        workflow.steps.append(step)
        _ = workflow.repairForwardEdges()
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard workflow.steps.indices.contains(destination) else { return }
        workflow.steps.swapAt(index, destination)
        repairedStepIDs = workflow.repairForwardEdges()
    }

    private func remove(_ index: Int) {
        guard workflow.steps.count > 1 else { return }
        workflow.steps.remove(at: index)
        repairedStepIDs = workflow.repairForwardEdges()
    }
}

private struct WorkflowStepCard: View {
    @Binding var step: AutomationWorkflowStep
    let index: Int
    let total: Int
    let laterSteps: [AutomationWorkflowStep]
    let connectors: [WorkflowConnectorOption]
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("\(index + 1)")
                    .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 20, height: 20)
                    .background(LocusTheme.signal.opacity(0.16))
                    .clipShape(Circle())
                Label(step.type.title, systemImage: symbol)
                    .font(.locus(size: 10, weight: .semibold))
                Spacer()
                Button(action: moveUp) { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .help("Move step earlier")
                    .accessibilityLabel("Move \(step.title) earlier")
                Button(action: moveDown) { Image(systemName: "arrow.down") }
                    .disabled(index + 1 == total)
                    .help("Move step later")
                    .accessibilityLabel("Move \(step.title) later")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .disabled(total == 1)
                    .help("Remove step")
                    .accessibilityLabel("Remove \(step.title)")
            }
            TextField("Step title", text: $step.title)
                .accessibilityIdentifier("workflow.step.\(step.id).title")
            switch step.type {
            case .agent: agentFields
            case .condition: conditionFields
            case .approval: approvalFields
            }
        }
        .padding(12)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(index + 1), \(step.type.title), \(step.title)")
    }

    private var symbol: String {
        switch step.type {
        case .agent: "sparkles"
        case .condition: "arrow.triangle.branch"
        case .approval: "hand.raised"
        }
    }

    @ViewBuilder private var agentFields: some View {
        TextEditor(text: Binding(
            get: { step.instructionTemplate ?? "" },
            set: { step.instructionTemplate = $0 }
        ))
        .font(.locus(size: 10))
        .frame(minHeight: 88)
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
        .accessibilityLabel("Agent instruction template")
        .accessibilityIdentifier("workflow.step.\(step.id).instruction")
        Picker("Work mode", selection: Binding(
            get: { step.mode ?? .work }, set: { step.mode = $0 }
        )) {
            ForEach(WorkMode.allCases) { Text($0.title).tag($0) }
        }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Declared outputs").font(.locus(size: 9, weight: .semibold))
                Spacer()
                Button("Add Output") {
                    var outputs = step.outputs ?? []
                    outputs.append(AutomationWorkflowOutput(
                        name: "field\(outputs.count + 1)", type: .string
                    ))
                    step.outputs = outputs
                }
            }
            ForEach(Array((step.outputs ?? []).indices), id: \.self) { outputIndex in
                HStack {
                    TextField("Field name", text: outputName(outputIndex))
                    Picker("Type", selection: outputType(outputIndex)) {
                        ForEach(AutomationWorkflowOutputType.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    Button(role: .destructive) {
                        step.outputs?.remove(at: outputIndex)
                    } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove output")
                }
            }
        }
        if !connectors.isEmpty {
            Menu(step.allowedConnectionIDs == nil
                ? "Allowed connectors (all)"
                : "Allowed connectors (\(step.allowedConnectionIDs?.count ?? 0))") {
                Button("Use all automation connectors") {
                    step.allowedConnectionIDs = nil
                }
                Divider()
                ForEach(connectors) { connector in
                    Toggle(connector.name, isOn: connectorBinding(connector.id))
                }
            }
            Text("A step can narrow the automation's connectors, never add new access.")
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
        }
        targetPicker("Continue to", selection: Binding(
            get: { step.nextStepID }, set: { step.nextStepID = $0 }
        ))
    }

    @ViewBuilder private var conditionFields: some View {
        TextField("Reference, e.g. steps.classify.urgent", text: Binding(
            get: { step.reference ?? "" }, set: { step.reference = $0 }
        ))
        Picker("Test", selection: Binding(
            get: { step.conditionOperator ?? "equals" },
            set: { step.conditionOperator = $0 }
        )) {
            Text("Equals").tag("equals")
            Text("Does not equal").tag("not_equals")
            Text("Greater than").tag("greater_than")
            Text("Less than").tag("less_than")
            Text("Is true").tag("is_true")
            Text("Is false").tag("is_false")
            Text("Exists").tag("exists")
        }
        if !["is_true", "is_false", "exists"].contains(step.conditionOperator ?? "") {
            TextField("Comparison value", text: Binding(
                get: { step.compareValue?.string ?? "" },
                set: { value in
                    if let number = Double(value) {
                        step.compareValue = .number(number)
                    } else if value.lowercased() == "true" {
                        step.compareValue = .bool(true)
                    } else if value.lowercased() == "false" {
                        step.compareValue = .bool(false)
                    } else {
                        step.compareValue = .string(value)
                    }
                }
            ))
        }
        targetPicker("If true", selection: Binding(
            get: { step.trueStepID }, set: { step.trueStepID = $0 }
        ))
        targetPicker("If false", selection: Binding(
            get: { step.falseStepID }, set: { step.falseStepID = $0 }
        ))
    }

    @ViewBuilder private var approvalFields: some View {
        TextEditor(text: Binding(
            get: { step.explanationTemplate ?? "" },
            set: { step.explanationTemplate = $0 }
        ))
        .font(.locus(size: 10))
        .frame(minHeight: 64)
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
        .accessibilityLabel("Approval explanation")
        targetPicker("If approved", selection: Binding(
            get: { step.approveStepID }, set: { step.approveStepID = $0 }
        ))
        Text("Rejecting cancels this occurrence.")
            .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
    }

    private func targetPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Finish").tag(Optional("finish"))
            ForEach(laterSteps) { later in
                Text(later.title).tag(Optional(later.id))
            }
        }
    }

    private func outputName(_ index: Int) -> Binding<String> {
        Binding(
            get: { step.outputs?[index].name ?? "" },
            set: { value in
                guard var outputs = step.outputs, outputs.indices.contains(index) else { return }
                outputs[index].name = value
                step.outputs = outputs
            }
        )
    }

    private func outputType(_ index: Int) -> Binding<AutomationWorkflowOutputType> {
        Binding(
            get: { step.outputs?[index].type ?? .string },
            set: { value in
                guard var outputs = step.outputs, outputs.indices.contains(index) else { return }
                outputs[index].type = value
                step.outputs = outputs
            }
        )
    }

    private func connectorBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { step.allowedConnectionIDs?.contains(id) == true },
            set: { enabled in
                var ids = step.allowedConnectionIDs ?? []
                if enabled, !ids.contains(id) { ids.append(id) }
                if !enabled { ids.removeAll { $0 == id } }
                step.allowedConnectionIDs = ids
            }
        )
    }
}

private struct WorkflowSimulationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let workflow: AutomationWorkflow
    let allowedConnectionIDs: [String]
    @State private var eventJSON = "{\n  \"subject\": \"Example\",\n  \"text\": \"Sample event\",\n  \"data\": {\"price\": 100}\n}"
    @State private var outputsJSON = "{}"
    @State private var result: WorkflowSimulationResponse?
    @State private var error: String?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Safe Simulation").font(.locus(size: 15, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Preview only: no model, connector, tool, file, command, or chat history is created.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            HStack(alignment: .top) {
                jsonEditor("Sample event", text: $eventJSON)
                jsonEditor("Mock Agent outputs", text: $outputsJSON)
            }
            Button("Run Simulation") { simulate() }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .keyboardShortcut(.return, modifiers: [.command])
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(LocusTheme.warning)
            }
            if let result {
                List(result.trace) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.locus(size: 10, weight: .semibold))
                        Text(
                            item.prompt ?? item.explanation
                                ?? item.outcome.map { $0 ? "Condition is true" : "Condition is false" }
                                ?? ""
                        )
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.inkSoft)
                        if item.needsMockOutputs == true {
                            Text("Add mock outputs for this step to continue the preview.")
                                .font(.locus(size: 8)).foregroundStyle(LocusTheme.warning)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
        .frame(width: 720, height: 620)
    }

    private func jsonEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.locus(size: 9, weight: .semibold))
            TextEditor(text: text)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 160)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
        }
    }

    private func simulate() {
        isRunning = true
        error = nil
        Task { @MainActor in
            defer { isRunning = false }
            do {
                result = try await model.simulateAutomationWorkflow(
                    workflow,
                    sampleEventJSON: eventJSON,
                    mockOutputsJSON: outputsJSON,
                    allowedConnectionIDs: allowedConnectionIDs
                )
            } catch {
                result = nil
                self.error = error.localizedDescription
            }
        }
    }
}
