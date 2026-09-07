import SwiftUI

struct TaskCapsuleView: View {
    @ObservedObject var model: TaskCapsuleModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLimits = false
    @State private var useAPIEstimateLimit = false
    @State private var apiEstimateLimit = 5.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                library
                    .frame(width: 235)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        waitingPlans
                        if let capsule = model.selectedCapsule { savedCapsule(capsule) }
                        else { draft }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 600, idealHeight: 730)
        .background(LocusTheme.surfaceCanvas)
        .foregroundStyle(LocusTheme.textPrimary)
        .task { await model.refresh() }
        .onChange(of: model.editingCapsuleID) { _, _ in synchronizeAPIEstimate() }
        .onAppear { synchronizeAPIEstimate() }
        .accessibilityIdentifier("capsules.sheet")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.locus(size: 24))
                .foregroundStyle(LocusTheme.accentAction)
            VStack(alignment: .leading, spacing: 3) {
                Text("Task Capsules").font(.title2.weight(.semibold))
                Text("Plan once. Continue with the model you choose.")
                    .font(.callout).foregroundStyle(LocusTheme.textSecondary)
            }
            Spacer()
            Button("Done") { model.isPresented = false; dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.locus())
                .accessibilityIdentifier("capsules.done")
        }
        .padding(20)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SAVED PLANS").font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.textSecondary)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.locus(.icon))
                .disabled(model.isRefreshing)
                .help("Refresh saved capsules")
                .accessibilityLabel("Refresh saved capsules")
            }
            Text(URL(fileURLWithPath: model.workspaceRoot).lastPathComponent)
                .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                .lineLimit(1).help(model.workspaceRoot)
            Button { model.newCapsule() } label: {
                Label("New capsule", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .buttonStyle(.locus(.card))
            .locusCard(radius: 8)
            .accessibilityIdentifier("capsules.new")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if model.capsules.isEmpty {
                        Text(model.isRefreshing ? "Loading saved plans…" : "Your saved plans will appear here. Each capsule keeps its model choices and instructions.")
                            .font(.callout).foregroundStyle(LocusTheme.textTertiary)
                            .padding(.vertical, 12)
                    }
                    ForEach(model.capsules) { capsule in
                        Button {
                            model.select(capsule)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(capsule.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text("\(stepCount(capsule.plan)) steps · Revision \(capsule.revision)")
                                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(model.selectedID == capsule.id ? LocusTheme.accentFill.opacity(0.22) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.locus(.card))
                        .accessibilityIdentifier("capsules.saved.\(capsule.id)")
                    }
                }
            }
            Button("Manage agent profiles") { model.manageProfiles() }
                .buttonStyle(.locus())
                .font(.caption)
        }
        .padding(16)
        .background(LocusTheme.surfaceStructural.opacity(0.5))
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Give the planner a goal").font(.title3.weight(.semibold))
            TextField("Capsule name (optional)", text: $model.draftTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capsules.title")
            VStack(alignment: .leading, spacing: 6) {
                Text("What should the task accomplish?").font(.callout.weight(.medium))
                TextEditor(text: $model.draftRequest)
                    .foregroundStyle(LocusTheme.inkSoft)
                    .tint(LocusTheme.accentAction)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 115)
                    .locusCard(radius: 8)
                    .accessibilityLabel("Capsule request")
                    .accessibilityIdentifier("capsules.request")
            }
            modelChoices
            Text("Use your connected ChatGPT or Kimi account, a local model, or an API profile. The planner writes the instructions; the implementation model follows the saved plan.")
                .font(.callout).foregroundStyle(LocusTheme.textSecondary)
            DisclosureGroup("Usage limits", isExpanded: $showLimits) {
                limits.padding(.top, 10)
            }
            .font(.callout)
            HStack(spacing: 12) {
                Button { model.generatePlan() } label: {
                    Label("Generate plan", systemImage: "sparkles")
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(LocusTheme.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.locus(.primary))
                .disabled(!model.canGenerate)
                .accessibilityIdentifier("capsules.generate")
                Button("Save current plan") { model.captureActivePlan() }
                    .buttonStyle(.locus())
                    .disabled(!model.canCapturePlan)
                    .help("Save the current conversation's completed plan using these model choices")
                    .accessibilityIdentifier("capsules.capture")
            }
            Text("Planning opens in the conversation. The completed plan is saved here for you to review and run.")
                .font(.caption).foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.profiles.isEmpty {
                Text("Create agent profiles for your planning and implementation models first.")
                    .font(.callout)
                Button("Set up agent profiles") { model.manageProfiles() }.buttonStyle(.locus())
            } else {
                profilePicker("Plan with", selection: $model.draftRecipe.plannerProfileID)
                profilePicker("Implement with", selection: $model.draftRecipe.executorProfileID)
                if model.implementationProfiles.isEmpty {
                    Text("Enable workspace write access for an implementation profile in Agent Profiles.")
                        .font(.caption).foregroundStyle(LocusTheme.warning)
                }
                Picker("Review with", selection: Binding(
                    get: { model.draftRecipe.reviewerProfileID ?? "" },
                    set: { model.draftRecipe.reviewerProfileID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("No separate reviewer").tag("")
                    if let reviewer = model.draftRecipe.reviewerProfileID,
                       !model.profiles.contains(where: { $0.id.uuidString == reviewer }) {
                        Text("Unavailable saved profile").tag(reviewer)
                    }
                    ForEach(model.profiles) { profile in
                        Text(model.profileLabel(profile)).tag(profile.id.uuidString)
                    }
                }
                .accessibilityIdentifier("capsules.reviewer")
            }
        }
        .padding(16).locusCard(radius: 10)
    }

    private func profilePicker(_ title: String, selection: Binding<String>) -> some View {
        let choices = title == "Implement with" ? model.implementationProfiles : model.profiles
        return Picker(title, selection: selection) {
            if !choices.contains(where: { $0.id.uuidString == selection.wrappedValue }) {
                Text("Choose an available profile").tag(selection.wrappedValue)
            }
            ForEach(choices) { profile in
                Text(model.profileLabel(profile)).tag(profile.id.uuidString)
            }
        }
        .accessibilityIdentifier(title == "Plan with" ? "capsules.planner" : "capsules.executor")
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("Planning: up to \(model.draftRecipe.planningCallLimit) model calls", value: $model.draftRecipe.planningCallLimit, in: 1...100)
            Stepper("Implementation: up to \(model.draftRecipe.executionCallLimit) model calls", value: $model.draftRecipe.executionCallLimit, in: 1...100)
            Stepper("Total review repair rounds: \(model.draftRecipe.maxRepairAttempts)", value: $model.draftRecipe.maxRepairAttempts, in: 0...7)
            Stepper("Total planner help requests: \(model.draftRecipe.maxPlannerEscalations)", value: $model.draftRecipe.maxPlannerEscalations, in: 0...10)
            Text("Repair rounds and planner help are allowances for the saved capsule, including later runs and revisions.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            Text("Implementation and review use their profile's per-response token limit. Your provider manages subscription allowances; model calls and tokens are not converted into a subscription dollar charge.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            Toggle("Optional implementation API cost estimate limit", isOn: $useAPIEstimateLimit)
                .onChange(of: useAPIEstimateLimit) { _, enabled in
                    model.draftRecipe.maximumEstimatedCost = enabled ? apiEstimateLimit : nil
                }
            if useAPIEstimateLimit {
                HStack {
                    Text("Estimated USD")
                    TextField("Amount", value: $apiEstimateLimit, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .onChange(of: apiEstimateLimit) { _, value in
                            model.draftRecipe.maximumEstimatedCost = value
                        }
                }
                Text("Applies to implementation and its review calls on API routes with configured prices. Planning calls, third-party tools, and image generation are excluded.")
                    .font(.caption).foregroundStyle(LocusTheme.textTertiary)
            }
        }
    }

    private func savedCapsule(_ capsule: TaskCapsule) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(capsule.title).font(.title2.weight(.semibold))
            Text("Revision \(capsule.revision) · \(stepCount(capsule.plan)) saved steps")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            if !capsule.request.isEmpty { Text(capsule.request).font(.callout).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 8) {
                routeSummary("Plan", id: capsule.recipe.plannerProfileID)
                routeSummary("Implement", id: capsule.recipe.executorProfileID)
                routeSummary("Review", id: capsule.recipe.reviewerProfileID)
                Text("Up to \(capsule.recipe.planningCallLimit) planning calls · \(capsule.recipe.executionCallLimit) implementation calls · \(capsule.recipe.maxRepairAttempts) total review repair rounds")
                    .font(.caption).foregroundStyle(LocusTheme.textTertiary)
            }
            .padding(14).locusCard(radius: 10)
            if model.isEditingRecipe {
                recipeEditor
            } else {
                Button("Edit models and limits") { model.beginEditingRecipe() }
                    .buttonStyle(.locus())
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("capsules.editRecipe")
            }
            if let issue = model.recipeError(capsule.recipe) {
                Text(issue).font(.callout).foregroundStyle(LocusTheme.warning)
            }
            planSteps(capsule.plan)
            HStack(spacing: 16) {
                Button { model.runSelected() } label: {
                    Label("Run saved capsule", systemImage: "play.fill")
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(LocusTheme.accentFill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.locus(.primary))
                .disabled(model.isBusy || model.isEditingRecipe || model.recipeError(capsule.recipe) != nil)
                .accessibilityIdentifier("capsules.run")
                if capsule.recipe.reviewerProfileID != nil {
                    Button("Review result") { model.reviewSelected() }
                        .buttonStyle(.locus())
                        .disabled(model.isBusy || model.isEditingRecipe)
                        .accessibilityIdentifier("capsules.review")
                }
            }
            if capsule.plan.stepDetails.contains(where: { !$0.files.isEmpty }) {
                Text("Execution uses this saved plan directly. Named files are checked for changes before implementation starts.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            } else {
                Text("This saved plan has no named files, so there are no source-change checks. Ask the planner to add file references.")
                    .font(.caption).foregroundStyle(LocusTheme.warning)
            }
            if capsule.recipe.maxPlannerEscalations > 0 {
                DisclosureGroup("Ask the planner for help") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(capsule.plannerHelpRequestsRemaining) of \(capsule.recipe.maxPlannerEscalations) total planner help requests remaining")
                            .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                        if capsule.plannerHelpRequestsRemaining == 0 {
                            Text("Use Edit models and limits to allow another request.")
                                .font(.caption).foregroundStyle(LocusTheme.warning)
                        }
                        TextField("Describe the blocker or the change needed", text: $model.plannerQuestion, axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder)
                        Button("Ask planner") { model.askPlannerForSelected() }
                            .buttonStyle(.locus())
                            .disabled(model.isBusy || model.isEditingRecipe || capsule.plannerHelpRequestsRemaining == 0
                                      || model.plannerQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Uses the planning model again and saves a new revision when the revised plan is complete.")
                            .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    }.padding(.top, 10)
                }
            }
            if !capsule.runs.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Run history").font(.headline)
                    ForEach(capsule.runs) { run in
                        HStack {
                            Text(run.stageTitle)
                            Spacer()
                            if let calls = run.modelCalls { Text("\(calls) calls") }
                            if let tokens = run.totalTokens { Text("\(tokens.formatted()) tokens") }
                            Text(run.status.capitalized)
                        }.font(.caption).foregroundStyle(LocusTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func routeSummary(_ stage: String, id: String?) -> some View {
        HStack(alignment: .top) {
            Text(stage).font(.callout.weight(.medium)).frame(width: 78, alignment: .leading)
            Text(model.profileLabel(id: id)).font(.callout).foregroundStyle(LocusTheme.textSecondary)
        }
    }

    private var recipeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Models and limits").font(.headline)
            modelChoices
            limits
            if let issue = model.recipeError(model.draftRecipe) {
                Text(issue).font(.caption).foregroundStyle(LocusTheme.warning)
            }
            Text("Saving creates a new revision with these choices. The saved instructions and source checks stay as they are.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            HStack(spacing: 16) {
                Button("Save choices") { Task { await model.saveRecipeChanges() } }
                    .buttonStyle(.locus())
                    .disabled(model.isBusy || model.recipeError(model.draftRecipe) != nil)
                    .accessibilityIdentifier("capsules.saveRecipe")
                Button("Cancel") { model.cancelRecipeEditing() }
                    .buttonStyle(.locus())
                    .disabled(model.isSaving)
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private func synchronizeAPIEstimate() {
        useAPIEstimateLimit = model.draftRecipe.maximumEstimatedCost != nil
        apiEstimateLimit = model.draftRecipe.maximumEstimatedCost ?? 5
    }

    private var waitingPlans: some View {
        ForEach(model.waitingPlans) { waiting in
            VStack(alignment: .leading, spacing: 8) {
                Label("Planning is waiting for your reply", systemImage: "bubble.left")
                    .font(.callout.weight(.semibold))
                Text(waiting.title).font(.callout).foregroundStyle(LocusTheme.textSecondary)
                Text("Reply in its conversation to keep planning, or cancel capsule planning to return that conversation to normal model selection.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                Button("Cancel capsule planning") { model.cancelPlanning(sessionID: waiting.id) }
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("capsules.cancelPlanning.\(waiting.id)")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).locusCard(radius: 10)
        }
    }

    private func stepCount(_ plan: PlanDocument) -> Int { plan.stepDetails.isEmpty ? plan.steps.count : plan.stepDetails.count }

    private func planSteps(_ plan: PlanDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved plan").font(.headline)
            if !plan.summary.isEmpty {
                DisclosureGroup("Plan overview") {
                    Text(plan.summary).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
            if plan.stepDetails.isEmpty {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").font(.callout).textSelection(.enabled)
                }
            } else {
                ForEach(Array(plan.stepDetails.enumerated()), id: \.element.id) { index, step in
                    DisclosureGroup("\(index + 1). \(step.title)") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(step.instructions).textSelection(.enabled)
                            if !step.files.isEmpty { Text("Files: " + step.files.joined(separator: ", ")) }
                            if !step.dependencies.isEmpty { Text("After: " + step.dependencies.joined(separator: ", ")) }
                            ForEach(Array(step.checks.enumerated()), id: \.offset) { _, check in
                                Label(check, systemImage: "checkmark.circle")
                            }
                        }.font(.callout).foregroundStyle(LocusTheme.textSecondary).padding(.top, 6)
                    }
                }
            }
            if !plan.tests.isEmpty {
                Text("Completion checks").font(.callout.weight(.semibold)).padding(.top, 4)
                ForEach(Array(plan.tests.enumerated()), id: \.offset) { _, check in
                    Label(check, systemImage: "checkmark.circle").font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isRefreshing || model.isSaving || !model.activeStageSessions.isEmpty {
                ProgressView().controlSize(.small)
            }
            Text(model.error ?? model.status ?? "Capsules are saved in this workspace. No model calls are made until you start a stage.")
                .font(.caption)
                .foregroundStyle(model.error == nil ? LocusTheme.textSecondary : LocusTheme.dangerForeground)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(minHeight: 44)
    }
}
