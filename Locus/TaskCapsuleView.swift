import SwiftUI

struct TaskCapsuleView: View {
    @ObservedObject var model: TaskCapsuleModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locusAccent) private var accent
    @State private var showLimits = false
    @State private var librarySearch = ""
    @State private var expandedSteps: Set<String> = []
    @FocusState private var requestFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 800 {
                        library.frame(width: 220)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        if geometry.size.width < 800 {
                            compactLibrary
                            Divider()
                        }
                        ScrollViewReader { scroll in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 22) {
                                    waitingPlans
                                    if let capsule = model.selectedCapsule { savedCapsule(capsule) }
                                    else { draft }
                                }
                                .padding(24)
                                .frame(maxWidth: 780, alignment: .leading)
                                .frame(maxWidth: .infinity)
                            }
                            .onChange(of: model.isEditingRecipe) { _, editing in
                                if editing { scroll.scrollTo("capsules.recipeEditor", anchor: .top) }
                            }
                        }
                        Divider()
                        actionBar
                    }
                }
            }
            if model.error != nil || model.status != nil || model.isRefreshing || model.isSaving {
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 560, idealHeight: 760)
        .background(LocusTheme.surfaceCanvas)
        .foregroundStyle(LocusTheme.textPrimary)
        .task { await model.refresh() }
        .onChange(of: model.selectedID) { _, _ in expandedSteps = [] }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.locus(size: 23))
                .foregroundStyle(LocusTheme.accentAction)
                .frame(width: 42, height: 42)
                .background(LocusTheme.accentFill.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Task Capsules").font(.title2.weight(.semibold))
                Text("Save a plan. Choose who builds it. Run when you’re ready.")
                    .font(.callout).foregroundStyle(LocusTheme.textSecondary)
            }
            Spacer(minLength: 12)
            Button("Done") { model.isPresented = false; dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.locus())
                .accessibilityIdentifier("capsules.done")
        }
        .padding(20)
    }

    private var filteredCapsules: [TaskCapsule] {
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.capsules : model.capsules.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.request.localizedCaseInsensitiveContains(query)
        }
    }

    private var workspaceName: String {
        model.workspaceRoot.isEmpty ? "Choose a workspace" : URL(fileURLWithPath: model.workspaceRoot).lastPathComponent
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your capsules").font(.headline)
                Spacer()
                refreshButton
            }
            Label(workspaceName, systemImage: "folder")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                .lineLimit(1).help(model.workspaceRoot)
            Button { model.newCapsule() } label: {
                Label("New capsule", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .buttonStyle(.locus(.card))
            .locusCard(radius: 9)
            .accessibilityIdentifier("capsules.new")
            if !model.capsules.isEmpty {
                TextField("Find a capsule", text: $librarySearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a capsule")
                    .accessibilityIdentifier("capsules.search")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if filteredCapsules.isEmpty {
                        Text(model.isRefreshing ? "Loading your capsules…" : model.capsules.isEmpty
                             ? "Your first capsule starts with a task. Once its plan is ready, it will appear here."
                             : "No capsules match your search.")
                            .font(.callout).foregroundStyle(LocusTheme.textTertiary)
                            .padding(.vertical, 12)
                    }
                    ForEach(filteredCapsules) { capsule in
                        Button { model.select(capsule) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(capsule.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text("\(stepSummary(capsule.plan)) · Revision \(capsule.revision)")
                                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                                Label(capsuleState(capsule), systemImage: capsule.runs.isEmpty ? "doc.text" : "clock")
                                    .font(.caption2).foregroundStyle(LocusTheme.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(model.selectedID == capsule.id ? LocusTheme.accentFill.opacity(0.17) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.locus(.card))
                        .accessibilityAddTraits(model.selectedID == capsule.id ? .isSelected : [])
                        .accessibilityIdentifier("capsules.saved.\(capsule.id)")
                    }
                }
            }
            Button("Manage agent profiles") { model.manageProfiles() }
                .buttonStyle(.locus()).font(.caption)
        }
        .padding(16)
        .background(LocusTheme.surfaceStructural.opacity(0.5))
    }

    private var compactLibrary: some View {
        HStack(spacing: 12) {
            Menu {
                Button("New capsule") { model.newCapsule() }
                if !model.capsules.isEmpty {
                    Divider()
                    ForEach(model.capsules) { capsule in
                        Button(capsule.title) { model.select(capsule) }
                    }
                }
            } label: {
                Label(model.selectedCapsule?.title ?? "New capsule", systemImage: "shippingbox")
                    .lineLimit(1)
            }
            .accessibilityLabel("Choose a capsule")
            .accessibilityIdentifier("capsules.libraryMenu")
            Spacer(minLength: 4)
            Button { model.newCapsule() } label: { Label("New", systemImage: "plus") }
                .buttonStyle(.locus())
                .accessibilityIdentifier("capsules.new")
            refreshButton
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var refreshButton: some View {
        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.locus(.icon)).disabled(model.isRefreshing)
            .help("Refresh saved capsules").accessibilityLabel("Refresh saved capsules")
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Turn a task into a reusable plan").font(.title3.weight(.semibold))
                Text("Your planner works out the steps. You review the plan before the implementation model makes changes.")
                    .font(.callout).foregroundStyle(LocusTheme.textSecondary)
                HStack(spacing: 8) {
                    workflowStep("1", "Describe")
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                    workflowStep("2", "Plan")
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                    workflowStep("3", "Review & run")
                }
                .font(.caption).foregroundStyle(LocusTheme.textTertiary).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("1", "Describe your task", detail: "Include the result you want and anything that should stay the same.")
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.draftRequest)
                        .foregroundStyle(LocusTheme.inkSoft).tint(LocusTheme.accentAction)
                        .font(.body).scrollContentBackground(.hidden)
                        .padding(8).frame(minHeight: 120)
                        .focused($requestFocused)
                        .accessibilityLabel("Capsule request")
                        .accessibilityIdentifier("capsules.request")
                    if model.draftRequest.isEmpty {
                        Text("What would you like to accomplish?")
                            .font(.body).foregroundStyle(LocusTheme.textTertiary)
                            .padding(.horizontal, 13).padding(.vertical, 16)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .locusCard(radius: 9)
                if model.draftRequest.isEmpty {
                    HStack(spacing: 8) {
                        Text("Try:").font(.caption).foregroundStyle(LocusTheme.textTertiary)
                        exampleButton("Fix a bug", request: "Fix [describe the issue] in [area of the project]. First reproduce the problem, then plan the smallest change and checks that show it is fixed.")
                        exampleButton("Build a feature", request: "Add [describe the feature] for [who will use it]. Plan the user experience, implementation, and checks. Keep [existing behavior] working.")
                        exampleButton("Improve a workflow", request: "Improve [describe the workflow] so [desired result]. Inspect the current approach, explain the proposed changes, and include checks for success.")
                    }
                }
                TextField("Name this capsule (optional)", text: $model.draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Capsule name, optional")
                    .accessibilityIdentifier("capsules.title")
                Text("Leave the name blank to use the planner’s title.")
                    .font(.caption).foregroundStyle(LocusTheme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("2", "Choose your models", detail: "An agent profile is a saved model, account, and set of permissions.")
                modelChoices
            }
            DisclosureGroup(isExpanded: $showLimits) {
                limits.padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Advanced · Usage limits").font(.callout.weight(.medium))
                    Text("\(model.draftRecipe.planningCallLimit) planning calls · \(model.draftRecipe.executionCallLimit) implementation calls")
                        .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                }
            }
            .padding(14).locusCard(radius: 10)
            if model.hasActivePlan {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.badge.plus").foregroundStyle(LocusTheme.accentAction)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already planned this in your conversation?").font(.callout.weight(.medium))
                        Text("Save that plan with these model choices and review it here.")
                            .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                        Button("Save current conversation plan") { model.captureActivePlan() }
                            .buttonStyle(.locus()).disabled(!model.canCapturePlan)
                            .accessibilityIdentifier("capsules.capture")
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading).locusCard(radius: 10)
            }
        }
    }

    private func workflowStep(_ number: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(number).font(.caption2.weight(.semibold))
                .frame(width: 20, height: 20)
                .background(LocusTheme.accentFill.opacity(0.14), in: Circle())
            Text(title).foregroundStyle(LocusTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ number: String, _ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(number). \(title)").font(.headline)
            Text(detail).font(.caption).foregroundStyle(LocusTheme.textSecondary)
        }
    }

    private func exampleButton(_ title: String, request: String) -> some View {
        Button(title) {
            model.draftRequest = request
            requestFocused = true
        }
        .font(.caption).buttonStyle(.locus())
        .help("Start with an editable example. Replace the bracketed details with your task.")
        .accessibilityIdentifier("capsules.example.\(title)")
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.profiles.isEmpty {
                Label("Set up your first agent profile", systemImage: "person.crop.circle.badge.plus")
                    .font(.callout.weight(.semibold))
                Text("One profile can do both jobs. In settings, choose Add Agent, select your account under Provider route and pick a model. Set Access ceiling to Workspace edits so it can implement your plan, then save.")
                    .font(.callout).foregroundStyle(LocusTheme.textSecondary)
                Button("Set up agent profiles") { model.manageProfiles() }
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("capsules.setupProfiles")
                Text("Your task description stays here. Reopen Task Capsules after saving your profile to continue.")
                    .font(.caption).foregroundStyle(LocusTheme.textTertiary)
            } else {
                profilePicker("Plan with", hint: "Inspects your workspace and writes the plan. Planning is read-only.", selection: $model.draftRecipe.plannerProfileID, implementation: false)
                Divider()
                profilePicker("Implement with", hint: "Follows the saved steps and can make changes when you choose Run plan.", selection: $model.draftRecipe.executorProfileID, implementation: true)
                if model.implementationProfiles.isEmpty {
                    Label("In Manage profiles, edit a profile and set Access ceiling to Workspace edits to enable implementation.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(LocusTheme.warning)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Review with").font(.callout.weight(.medium))
                        Text("Optional").font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    }
                    Picker("Review with", selection: Binding(
                        get: { model.draftRecipe.reviewerProfileID ?? "" },
                        set: { model.draftRecipe.reviewerProfileID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("No separate reviewer").tag("")
                        if let reviewer = model.draftRecipe.reviewerProfileID,
                           !model.profiles.contains(where: { $0.id.uuidString.caseInsensitiveCompare(reviewer) == .orderedSame }) {
                            Text("Unavailable saved profile — choose another").tag(reviewer)
                        }
                        ForEach(model.profiles) { profile in
                            Text(model.profileLabel(profile)).tag(profile.id.uuidString)
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capsules.reviewer")
                    Text("Checks the implementation and can request fixes within your repair allowance.")
                        .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                }
                HStack {
                    Text("You can use the same profile for more than one role.")
                        .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    Spacer(minLength: 8)
                    Button("Manage profiles") { model.manageProfiles() }
                        .buttonStyle(.locus()).font(.caption)
                }
            }
        }
        .padding(16).locusCard(radius: 10)
    }

    private func profilePicker(_ title: String, hint: String, selection: Binding<String>, implementation: Bool) -> some View {
        let choices = implementation ? model.implementationProfiles : model.profiles
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Picker(title, selection: selection) {
                if !choices.contains(where: { $0.id.uuidString.caseInsensitiveCompare(selection.wrappedValue) == .orderedSame }) {
                    Text(selection.wrappedValue.isEmpty ? "Choose a profile" : "Unavailable saved profile — choose another")
                        .tag(selection.wrappedValue)
                }
                ForEach(choices) { profile in
                    Text(model.profileLabel(profile)).tag(profile.id.uuidString)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(implementation ? "capsules.executor" : "capsules.planner")
            Text(hint).font(.caption).foregroundStyle(LocusTheme.textSecondary)
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A model call is one request to a model. These allowances stop a stage from continuing indefinitely.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            Stepper("Planning: up to \(model.draftRecipe.planningCallLimit) calls", value: $model.draftRecipe.planningCallLimit, in: 1...100)
            Stepper("Implementation: up to \(model.draftRecipe.executionCallLimit) calls", value: $model.draftRecipe.executionCallLimit, in: 1...100)
            Stepper("Review repair rounds: \(model.draftRecipe.maxRepairAttempts)", value: $model.draftRecipe.maxRepairAttempts, in: 0...7)
            Stepper("Planner help requests: \(model.draftRecipe.maxPlannerEscalations)", value: $model.draftRecipe.maxPlannerEscalations, in: 0...10)
            Text("Repair rounds and planner help are shared across this capsule’s runs and revisions. Without a reviewer, repair rounds are unused.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            Toggle("Set an estimated API cost limit", isOn: Binding(
                get: { model.draftRecipe.maximumEstimatedCost != nil },
                set: { model.draftRecipe.maximumEstimatedCost = $0 ? 5 : nil }
            ))
            if model.draftRecipe.maximumEstimatedCost != nil {
                HStack {
                    Text("Estimated USD")
                    TextField("Amount", value: Binding(
                        get: { model.draftRecipe.maximumEstimatedCost ?? 5 },
                        set: { model.draftRecipe.maximumEstimatedCost = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("Estimated API cost limit in US dollars")
                }
                Text("An estimate, not a billing cap. Covers implementation and its automatic review with configured API prices. Excludes planning, standalone review, tools, and image generation.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            }
            Text("Your provider manages subscription allowances. Locus does not convert subscription calls or tokens into a dollar charge. Profile response-token and runtime limits still apply.")
                .font(.caption).foregroundStyle(LocusTheme.textTertiary)
        }
        .font(.callout)
    }

    private func savedCapsule(_ capsule: TaskCapsule) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label(capsuleState(capsule), systemImage: "doc.text")
                    .font(.caption.weight(.medium)).foregroundStyle(LocusTheme.accentAction)
                Text(capsule.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("Revision \(capsule.revision) · \(stepSummary(capsule.plan)) · \(workspaceName)")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                if !capsule.request.isEmpty {
                    Text(capsule.request).font(.callout).foregroundStyle(LocusTheme.textSecondary).textSelection(.enabled)
                }
            }
            if model.isEditingRecipe {
                recipeEditor
                    .id("capsules.recipeEditor")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Models & limits").font(.headline)
                        Spacer()
                        Button("Edit") { model.beginEditingRecipe() }
                            .buttonStyle(.locus()).disabled(model.isBusy)
                            .accessibilityLabel("Edit models and limits")
                            .accessibilityIdentifier("capsules.editRecipe")
                    }
                    routeSummary("Plan", id: capsule.recipe.plannerProfileID)
                    routeSummary("Implement", id: capsule.recipe.executorProfileID)
                    routeSummary("Review", id: capsule.recipe.reviewerProfileID)
                    Text("Up to \(capsule.recipe.planningCallLimit) planning calls · \(capsule.recipe.executionCallLimit) implementation calls")
                        .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                }
                .padding(16).locusCard(radius: 10)
            }
            if let issue = model.recipeError(capsule.recipe), !model.isEditingRecipe {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(LocusTheme.warning)
            }
            planSteps(capsule.plan)
            sourceCheckSummary(capsule)
            plannerHelp(capsule)
            if !capsule.runs.isEmpty { runHistory(capsule) }
        }
    }

    private func capsuleState(_ capsule: TaskCapsule) -> String {
        guard let run = capsule.runs.last(where: { $0.stage == "execute" || $0.stage == "review" }) else {
            return "Plan saved · Ready to review"
        }
        return "Last run: \(run.stageTitle) · \(runStatus(run))"
    }

    private func runStatus(_ run: TaskCapsuleRun) -> String {
        switch run.status.lowercased() {
        case "completed", "complete", "succeeded": return "Completed"
        case "failed", "error": return "Needs attention"
        case "interrupted", "cancelled", "canceled", "stopped": return "Stopped"
        case "running", "active": return "In progress"
        case "pending", "queued": return "Waiting"
        default: return run.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func sourceCheckSummary(_ capsule: TaskCapsule) -> some View {
        let fileCount = Set(capsule.plan.stepDetails.flatMap(\.files)).count
        return Label {
            Text(fileCount > 0
                 ? "Locus checks \(fileCount) named \(fileCount == 1 ? "file" : "files") for changes before running. If anything has changed, ask the planner to update the plan."
                 : "This plan has no named files to check before running. You can ask the planner to add file references.")
        } icon: {
            Image(systemName: fileCount > 0 ? "doc.text.magnifyingglass" : "info.circle")
        }
        .font(.caption).foregroundStyle(fileCount > 0 ? LocusTheme.textSecondary : LocusTheme.warning)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).locusCard(radius: 10)
    }

    private func routeSummary(_ stage: String, id: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(stage).font(.callout.weight(.medium)).frame(width: 74, alignment: .leading)
            Text(id == nil ? "No separate reviewer" : model.profileLabel(id: id))
                .font(.callout).foregroundStyle(LocusTheme.textSecondary).textSelection(.enabled)
        }
    }

    private var recipeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Editing models & limits", systemImage: "pencil").font(.headline)
            modelChoices
            DisclosureGroup("Usage limits", isExpanded: $showLimits) { limits.padding(.top, 12) }
            Text("Save to create a new revision. Your plan, file checks, and run history are preserved.")
                .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            if let issue = model.recipeError(model.draftRecipe) {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(LocusTheme.warning)
            }
        }
        .padding(16).locusCard(radius: 10)
    }

    private var waitingPlans: some View {
        ForEach(model.waitingPlans) { waiting in
            VStack(alignment: .leading, spacing: 9) {
                Label("Finish your plan", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.callout.weight(.semibold))
                Text(waiting.title).font(.callout).foregroundStyle(LocusTheme.textSecondary)
                Text("Open the conversation to answer questions or continue planning. The finished plan will be saved here.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                HStack(spacing: 14) {
                    Button("Continue planning") { model.openConversation(sessionID: waiting.id) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("capsules.continuePlanning.\(waiting.id)")
                    Button("Cancel planning") { model.cancelPlanning(sessionID: waiting.id) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("capsules.cancelPlanning.\(waiting.id)")
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).locusCard(radius: 10)
        }
    }

    private func plannerHelp(_ capsule: TaskCapsule) -> some View {
        DisclosureGroup("Update the plan or ask for help") {
            VStack(alignment: .leading, spacing: 10) {
                if capsule.plannerHelpRequestsRemaining > 0 {
                    Text("Describe a blocker or change. Your planning model will inspect the workspace and save a revised plan for you to review.")
                        .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                    TextField("What should the planner change or investigate?", text: $model.plannerQuestion, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Question for the planner")
                        .accessibilityIdentifier("capsules.plannerQuestion")
                    HStack {
                        Button("Ask planner") { model.askPlannerForSelected() }
                            .buttonStyle(.locus())
                            .disabled(model.isBusy || model.isEditingRecipe || model.recipeError(capsule.recipe) != nil
                                      || model.plannerQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("capsules.askPlanner")
                        Spacer()
                        Text("\(capsule.plannerHelpRequestsRemaining) of \(capsule.recipe.maxPlannerEscalations) requests left")
                            .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    }
                } else {
                    Text(capsule.recipe.maxPlannerEscalations == 0
                         ? "Planner help is turned off for this capsule. Edit its usage limits to allow a request."
                         : "You’ve used this capsule’s planner help allowance. Edit its usage limits to allow another request.")
                        .font(.callout).foregroundStyle(LocusTheme.textSecondary)
                    Button("Edit usage limits") {
                        model.beginEditingRecipe()
                        showLimits = true
                    }
                    .buttonStyle(.locus()).disabled(model.isBusy || model.isEditingRecipe)
                }
            }
            .padding(.top, 10)
        }
        .font(.callout.weight(.medium))
        .padding(14).locusCard(radius: 10)
    }

    private func stepCount(_ plan: PlanDocument) -> Int { plan.stepDetails.isEmpty ? plan.steps.count : plan.stepDetails.count }

    private func stepSummary(_ plan: PlanDocument) -> String {
        let count = stepCount(plan)
        return "\(count) \(count == 1 ? "step" : "steps")"
    }

    private func planSteps(_ plan: PlanDocument) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Review your plan").font(.headline)
                Spacer()
                if !plan.stepDetails.isEmpty {
                    Button(expandedSteps.count == plan.stepDetails.count ? "Collapse steps" : "Expand steps") {
                        expandedSteps = expandedSteps.count == plan.stepDetails.count ? [] : Set(plan.stepDetails.map(\.id))
                    }
                    .buttonStyle(.locus()).font(.caption)
                    .accessibilityIdentifier("capsules.expandSteps")
                }
            }
            if !plan.summary.isEmpty {
                Text(plan.summary).font(.callout).foregroundStyle(LocusTheme.textSecondary).textSelection(.enabled)
            }
            if plan.stepDetails.isEmpty {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").font(.callout).textSelection(.enabled)
                }
            } else {
                ForEach(Array(plan.stepDetails.enumerated()), id: \.element.id) { index, step in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedSteps.contains(step.id) },
                        set: { if $0 { expandedSteps.insert(step.id) } else { expandedSteps.remove(step.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(step.instructions).textSelection(.enabled)
                            if !step.files.isEmpty {
                                Text("Files: " + step.files.joined(separator: ", ")).textSelection(.enabled)
                            }
                            if !step.dependencies.isEmpty {
                                Text("After: " + step.dependencies.map { dependency in
                                    plan.stepDetails.first(where: { $0.id == dependency })?.title ?? dependency
                                }.joined(separator: ", "))
                            }
                            ForEach(Array(step.checks.enumerated()), id: \.offset) { _, check in
                                Label(check, systemImage: "checkmark.circle").textSelection(.enabled)
                            }
                        }
                        .font(.callout).foregroundStyle(LocusTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").font(.caption.weight(.semibold))
                                .frame(width: 24, height: 24)
                                .background(LocusTheme.accentFill.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                            Text(step.title).font(.callout.weight(.medium)).padding(.top, 3)
                        }
                    }
                    .padding(12).locusCard(radius: 9)
                    .accessibilityIdentifier("capsules.step.\(step.id)")
                }
            }
            planNotes("Completion checks", notes: plan.tests, icon: "checkmark.circle")
            planNotes("Keep in mind", notes: plan.constraints, icon: "pin")
            planNotes("Design decisions", notes: plan.decisions, icon: "lightbulb")
        }
    }

    @ViewBuilder
    private func planNotes(_ title: String, notes: [String], icon: String) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout.weight(.semibold))
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: icon).font(.callout)
                        .foregroundStyle(LocusTheme.textSecondary).textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
    }

    private func runHistory(_ capsule: TaskCapsule) -> some View {
        DisclosureGroup("Run history (\(capsule.runs.count))") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(capsule.runs.reversed()) { run in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.stageTitle).font(.callout.weight(.medium))
                            Text(runStatus(run)).font(.caption).foregroundStyle(LocusTheme.textSecondary)
                            if run.modelCalls != nil || run.totalTokens != nil {
                                Text([run.modelCalls.map { "\($0) calls" }, run.totalTokens.map { "\($0.formatted()) tokens" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                            }
                        }
                        Spacer()
                        if let sessionID = run.sessionID, !sessionID.isEmpty {
                            Button("Open conversation") { model.openConversation(sessionID: sessionID) }
                                .buttonStyle(.locus()).font(.caption)
                                .accessibilityIdentifier("capsules.runConversation.\(run.id)")
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .font(.callout.weight(.medium))
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isEditingRecipe {
                HStack(spacing: 14) {
                    Button { Task { await model.saveRecipeChanges() } } label: {
                        Text("Save choices")
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(Color(nsColor: accent.brandInkNSColor()))
                            .background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                        .buttonStyle(.locus(.primary))
                        .disabled(model.isBusy || model.recipeError(model.draftRecipe) != nil)
                        .accessibilityIdentifier("capsules.saveRecipe")
                    Button("Cancel") { model.cancelRecipeEditing() }
                        .buttonStyle(.locus()).disabled(model.isSaving)
                }
                Text("Save or cancel your changes before starting a stage.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            } else if let capsule = model.selectedCapsule {
                HStack(spacing: 14) {
                    Button { model.runSelected() } label: {
                        Label(capsule.runs.contains(where: { $0.stage == "execute" }) ? "Run again" : "Run plan", systemImage: "play.fill")
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(Color(nsColor: accent.brandInkNSColor()))
                            .background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.locus(.primary))
                    .disabled(model.isBusy || model.recipeError(capsule.recipe) != nil)
                    .accessibilityIdentifier("capsules.run")
                    if capsule.recipe.reviewerProfileID != nil {
                        Button("Review result") { model.reviewSelected() }
                            .buttonStyle(.locus())
                            .disabled(model.isBusy || model.recipeError(capsule.recipe) != nil)
                            .help("Ask the review model to inspect the result without changing files")
                            .accessibilityIdentifier("capsules.review")
                    }
                    Spacer(minLength: 0)
                }
                Text(model.isBusy ? "A task is in progress. Follow its conversation to see updates."
                     : capsule.runs.contains(where: { $0.stage == "execute" })
                     ? "Review previous changes before running again. A changed file may need a revised plan."
                     : "Starts in your conversation and may change files in \(workspaceName).")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            } else if model.profiles.isEmpty {
                Button { model.manageProfiles() } label: {
                    Label("Set up models", systemImage: "person.crop.circle.badge.plus")
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .foregroundStyle(Color(nsColor: accent.brandInkNSColor()))
                        .background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.locus(.primary))
                .accessibilityIdentifier("capsules.setupModels")
                Text("One agent profile can plan and run your task. Your description is kept while you set it up.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            } else {
                HStack(spacing: 12) {
                    Button { model.generatePlan() } label: {
                        Label("Generate plan", systemImage: "sparkles")
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(Color(nsColor: accent.brandInkNSColor()))
                            .background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.locus(.primary)).disabled(!model.canGenerate)
                    .accessibilityIdentifier("capsules.generate")
                    Text("Next: review the saved plan")
                        .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                }
                Text(model.planningUnavailableReason ?? "Planning opens in your conversation. You decide when implementation starts.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                    .accessibilityIdentifier("capsules.nextStep")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.surfaceStructural.opacity(0.45))
    }

    private var statusBar: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.isRefreshing || model.isSaving {
                ProgressView().controlSize(.small)
            } else if model.error != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(LocusTheme.dangerForeground)
            } else {
                Image(systemName: "info.circle").foregroundStyle(LocusTheme.textSecondary)
            }
            Text(model.error ?? model.status ?? (model.isSaving ? "Saving capsule…" : "Refreshing capsules…"))
                .font(.caption)
                .foregroundStyle(model.error == nil ? LocusTheme.textSecondary : LocusTheme.dangerForeground)
                .textSelection(.enabled)
                .accessibilityIdentifier("capsules.status")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
