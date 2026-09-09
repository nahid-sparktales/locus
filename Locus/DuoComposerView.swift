import SwiftUI

struct DuoComposerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var duo: DuoModel
    @ObservedObject var capsules: TaskCapsuleModel

    private var task: DuoTask? { model.duoTask }
    private var locked: Bool { task != nil || model.isBusy || model.hasPendingPermission }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) { choices }
            if let task {
                HStack {
                    Text(status(task)).font(.locus(size: 11, weight: .semibold))
                    Spacer()
                    if !model.isBusy, task.phase != .executing {
                        Button("New plan") { model.newDuoPlan() }
                            .accessibilityIdentifier("duo.newPlan")
                    }
                }
                if let capsule = task.capsule, task.phase == .ready {
                    Text(capsule.plan.title).font(.locus(size: 13, weight: .semibold))
                    DisclosureGroup("Review plan · \(capsule.plan.steps.count) steps") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(capsule.plan.summary)
                                ForEach(Array(capsule.plan.decisions.enumerated()), id: \.offset) { _, item in Text("Decision: \(item)") }
                                ForEach(Array(capsule.plan.constraints.enumerated()), id: \.offset) { _, item in Text("Constraint: \(item)") }
                                if capsule.plan.stepDetails.isEmpty {
                                    ForEach(Array(capsule.plan.steps.enumerated()), id: \.offset) { index, item in Text("\(index + 1). \(item)") }
                                } else {
                                    ForEach(capsule.plan.stepDetails) { step in
                                        Text(step.title).bold()
                                        Text(step.instructions)
                                        if !step.files.isEmpty { Text("Files: " + step.files.joined(separator: ", ")) }
                                        ForEach(Array(step.checks.enumerated()), id: \.offset) { _, check in Text("Check: \(check)") }
                                        ForEach(Array(step.acceptanceChecks.enumerated()), id: \.offset) { _, check in
                                            if let requirement = check["requirement"]?.string { Text("Check: \(requirement)") }
                                        }
                                    }
                                }
                                ForEach(Array(capsule.plan.tests.enumerated()), id: \.offset) { _, item in Text("Verify: \(item)") }
                                ForEach(Array(capsule.plan.acceptanceChecks.enumerated()), id: \.offset) { _, check in
                                    if let requirement = check["requirement"]?.string { Text("Verify: \(requirement)") }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                        }.frame(maxHeight: 240)
                    }
                    .accessibilityIdentifier("duo.plan")
                    HStack {
                        Button("Accept & build") { model.acceptDuo() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("duo.accept")
                        Button("Revise") { model.reviseDuo() }
                            .accessibilityIdentifier("duo.revise")
                    }.disabled(model.isBusy || model.hasPendingPermission || !model.isAgentOnline)
                } else if task.phase == .paused {
                    HStack {
                        Button("Resume") { model.acceptDuo(resume: true) }.accessibilityIdentifier("duo.resume")
                        Button("Ask planner for help") {
                            model.reviseDuo(feedback: "Inspect the partial work and the failed checks. Resolve the blocker and submit an updated plan for acceptance.")
                        }
                        Button("Review recovery") { model.openDuoRecovery() }
                    }.disabled(model.isBusy || model.hasPendingPermission || !model.isAgentOnline)
                } else if task.phase == .saving, !model.isBusy {
                    Button("Retry saving plan") { Task { await model.saveDuoPlanAgain() } }
                        .disabled(capsules.isSaving)
                }
                if let error = task.error { Text(error).foregroundStyle(.red) }
            } else {
                Text("Review the plan, then accept to start the builder.")
                    .foregroundStyle(LocusTheme.muted)
            }
            if let error = capsules.error { Text(error).foregroundStyle(.red) }
        }
        .font(.locus(size: 10))
        .padding(12)
        .locusCard(radius: 12)
        .accessibilityIdentifier("duo.panel")
        .task(id: model.currentSessionID) { await model.refreshDuo() }
        .onChange(of: model.isBusy) { if !model.isBusy { Task { await model.refreshDuo() } } }
        .onChange(of: capsules.isPresented) { if !capsules.isPresented { Task { await model.refreshDuo() } } }
    }

    @ViewBuilder private var choices: some View {
        choice(planner: true, profile: task?.planner ?? duo.saved.planner)
        Image(systemName: "arrow.right").foregroundStyle(LocusTheme.muted).accessibilityHidden(true)
        choice(planner: false, profile: task?.executor ?? duo.saved.executor)
    }

    private func choice(planner: Bool, profile: AgentProfile?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(planner ? "Plan with" : "Build with").foregroundStyle(LocusTheme.muted)
            if locked {
                Text(model.duoLabel(profile)).lineLimit(1).truncationMode(.middle)
                    .help(model.duoLabel(profile))
                    .accessibilityIdentifier(planner ? "duo.planner" : "duo.executor")
            } else {
                Menu {
                    ForEach(model.modelPickerSections) { section in
                        Section(section.title) {
                            ForEach(section.models, id: \.self) { name in
                                Button(name) { model.selectDuoModel(account: section.account, model: name, planner: planner) }
                            }
                            if let message = section.emptyMessage { Text(message) }
                        }
                    }
                } label: {
                    Text(model.duoLabel(profile)).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityIdentifier(planner ? "duo.planner" : "duo.executor")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ task: DuoTask) -> String {
        switch task.phase {
        case .planning: "Planning · \(task.planner.model)"
        case .saving: "Saving plan"
        case .ready: "Ready to build · \(task.executor.model)"
        case .executing: "Building · \(task.executor.model)"
        case .paused: "Build paused · \(task.executor.model)"
        case .completed: "Follow-ups use \(task.executor.model)"
        }
    }
}
