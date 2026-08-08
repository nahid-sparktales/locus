import AppKit
import SwiftUI

/// The right-hand inspector: a tab shell around workspace run state, files,
/// instructions, terminal, preview and checkpoints, with a drag handle on its
/// leading edge.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabStrip()
                .environmentObject(model)

            Group {
                switch model.inspectorTab {
                case .plan:
                    InspectorPlanTab()
                case .changes:
                    InspectorChangesTab()
                case .files:
                    InspectorFilesTab()
                case .terminal:
                    InspectorTerminalTab()
                case .preview:
                    InspectorPreviewTab()
                case .checkpoints:
                    InspectorCheckpointsTab()
                case .runs:
                    InspectorRunsTab()
                case .agents:
                    InspectorAgentsTab()
                }
            }
            .environmentObject(model)
            .frame(maxHeight: .infinity)
        }
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .leading) {
            InspectorResizeHandle()
                .environmentObject(model)
        }
    }
}

/// Shared empty state for inspector tabs.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 23))
                .foregroundStyle(LocusTheme.muted)
            Text(title)
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

/// Icon-first tab strip. Labels appear only when the panel is wide enough, and
/// the attention badge sits on the icon so it survives icon-only mode.
private struct InspectorTabStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { tab in
                tabButton(tab)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.inspectorCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide inspector")
            .accessibilityLabel("Hide inspector")
            .accessibilityIdentifier("inspector.collapse")
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let selected = model.inspectorTab == tab
        return Button {
            model.selectInspectorTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        badge(for: tab)
                    }
                if model.inspectorShowsLabels {
                    Text(tab.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .fill(LocusTheme.ink)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel("\(tab.title) inspector")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("inspector.tab.\(tab.rawValue)")
    }

    @ViewBuilder
    private func badge(for tab: InspectorTab) -> some View {
        if tab == .changes, model.changedFileCount > 0 {
            // Coral only while the change is still unseen; once you have opened
            // the tab the count stays but stops asking for attention.
            let unseen = model.changesHaveUnseenUpdate
            Text(model.changedFileCount > 99 ? "99+" : "\(model.changedFileCount)")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(height: 11)
                .background(unseen ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .offset(x: 9, y: -5)
                .accessibilityElement()
                .accessibilityLabel(
                    unseen
                        ? "\(model.changedFileCount) changed files, new since you last looked"
                        : "\(model.changedFileCount) changed files"
                )
                .accessibilityIdentifier("inspector.tab.changes.badge")
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .offset(x: 5, y: -3)
                .accessibilityElement()
                .accessibilityLabel("Plan updated")
                .accessibilityIdentifier("inspector.tab.plan.badge")
        }
    }
}

/// Drag target on the inspector's leading divider.
private struct InspectorResizeHandle: View {
    @EnvironmentObject private var model: AppModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // `.set()` rather than push/pop: an unbalanced pair is
                        // the classic way to leave the cursor stuck.
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // Accumulate from a captured start width so the
                                // panel cannot drift over a long drag.
                                let start = startWidth ?? model.inspectorWidth
                                if startWidth == nil { startWidth = start }
                                model.setInspectorWidth(start - value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                model.commitInspectorWidth()
                            }
                    )
                    .onTapGesture(count: 2) {
                        model.setInspectorWidth(AppSettings.defaultInspectorWidth)
                        model.commitInspectorWidth()
                    }
                    .accessibilityLabel("Resize inspector")
                    .accessibilityIdentifier("inspector.resizeHandle")
            }
    }
}

struct InspectorRunsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewMode = "timeline"
    @State private var filter = ""
    @State private var draftPlan: DispatchPlan?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = model.lifecycleRecoveryMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text(message)
                        .font(.system(size: 9))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        model.dismissLifecycleRecoveryMessage()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss recovery explanation")
                }
                .padding(10)
                .background(LocusTheme.signal.opacity(0.1))
                .accessibilityIdentifier("runs.recoveryExplanation")
            }
            if let plan = draftPlan, model.pendingDispatchPlan != nil {
                dispatchEditor(plan)
            } else if let run = model.selectedOrchestrationRun {
                runBody(run)
            } else {
                InspectorPlaceholder(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No team run selected",
                    message: "Team runs appear here with their ordered events, attempts, checkpoints, routing, and recovery controls.",
                    identifier: "runs.empty"
                )
            }
        }
        .task {
            if model.orchestrationRuns.isEmpty, model.selectedOrchestrationRun == nil {
                await model.refreshOrchestrationRuns()
            }
        }
        .onChange(of: model.pendingDispatchPlan) { _, value in draftPlan = value }
        .onAppear { draftPlan = model.pendingDispatchPlan }
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("TEAM RUN INSPECTOR")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Button {
                    Task { await model.refreshOrchestrationRuns() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh run history")
            }
            if !model.orchestrationRuns.isEmpty {
                Picker("Run", selection: Binding(
                    get: { model.selectedOrchestrationRun?.id ?? "" },
                    set: { id in Task { await model.loadOrchestrationRun(id) } }
                )) {
                    ForEach(model.orchestrationRuns) { run in
                        Text("\(run.teamName ?? "Team") · \(run.state.replacingOccurrences(of: "_", with: " "))")
                            .tag(run.id)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private func runBody(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            runSummary(run)
            Picker("View", selection: $viewMode) {
                Text("Timeline").tag("timeline")
                Text("Dependencies").tag("graph")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if viewMode == "timeline" { timeline(run) } else { dependencyView(run) }
        }
    }

    private func runSummary(_ run: OrchestrationRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.teamName ?? "Team run").font(.system(size: 11, weight: .bold))
                    Text("\(run.state.replacingOccurrences(of: "_", with: " ")) · \(run.lastSequence) events")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("runs.state")
                }
                Spacer()
                runActions(run)
            }
            if let reason = run.recoveryReason, run.recoverable {
                Label(reason, systemImage: "arrow.clockwise.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let checkpoint = run.checkpoint {
                Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " ")) at event \(checkpoint.sequence)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            if let task = model.activeTaskRecord, task.id == run.taskID {
                HStack(spacing: 7) {
                    Button("Apply to Workspace") { model.applyActiveTaskToWorkspace() }
                        .disabled(model.isBusy || !model.taskHasChanges)
                    Button("Copy Patch") { model.copyActiveTaskPatch() }
                        .disabled(model.isBusy || !model.taskHasChanges)
                    Menu {
                        Button("Open Checkout") { model.openActiveTaskCheckout() }
                        Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(LocusTheme.paperDeep.opacity(0.5))
    }

    @ViewBuilder
    private func runActions(_ run: OrchestrationRun) -> some View {
        Menu {
            Button(run.pinned ? "Unpin Run" : "Pin Run") {
                model.setOrchestrationPinned(run, pinned: !run.pinned)
            }
            if run.recoverable {
                Button("Resume") { model.resumeOrchestration(run) }
            }
            if run.taskID != nil && !run.legacy {
                Button("Replay Same Baseline") { model.replayOrchestration(run) }
            }
            if !run.legacy {
                Button("Duplicate from Current Workspace") { model.duplicateOrchestration(run) }
            }
            if run.id == model.orchestrationRunID, model.isBusy {
                Button("Pause at Safe Boundary") { model.pauseOrchestration(run.id) }
                Button("Stop Run", role: .destructive) { model.cancelOrchestration(run.id) }
            }
            Menu("Export") {
                Button("Redacted .locusrun") {
                    Task { await model.exportOrchestration(run.id, includeContent: false) }
                }
                Button("Include Visible Content…") {
                    Task { await model.exportOrchestration(run.id, includeContent: true) }
                }
            }
            Divider()
            Button("Discard Run", role: .destructive) { model.discardOrchestration(run.id) }
                .disabled(model.isBusy && run.id == model.orchestrationRunID)
            if run.taskID != nil && ["discarded", "cancelled", "completed", "failed"].contains(run.state) {
                Button("Clean Up Managed Checkout", role: .destructive) {
                    model.cleanupOrchestrationCheckout(run)
                }
                .disabled(model.isBusy)
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
    }

    private func timeline(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            TextField("Filter agent, event, state, or attempt", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("runs.filter")
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEvents) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(event.sequence)")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .frame(width: 30, alignment: .trailing)
                            Circle().fill(color(for: event.type)).frame(width: 6, height: 6).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.type.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: 8, weight: .bold))
                                Text(event.title)
                                    .font(.system(size: 8))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .lineLimit(4)
                                if let detail = event.detail, detail != event.title {
                                    Text(detail)
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                        .lineLimit(12)
                                        .textSelection(.enabled)
                                }
                                if let job = event.jobID {
                                    Text("job \(job)\(event.attemptID.map { " · \($0)" } ?? "")")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func dependencyView(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.attempts ?? []) { attempt in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: attempt.state == "completed" ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(attempt.state == "completed" ? LocusTheme.success : LocusTheme.signalDeep)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                                    .font(.system(size: 9, weight: .bold))
                                Text("attempt \(attempt.attempt)")
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                Spacer()
                                if attempt.state != "running"
                                    && !model.isCodingAttempt(attempt, in: run) {
                                    Menu {
                                        Button("Retry with Same Agent") {
                                            model.retryOrchestrationJob(attempt, in: run)
                                        }
                                        let candidates = model.reassignmentCandidates(
                                            for: attempt, in: run
                                        )
                                        if !candidates.isEmpty {
                                            Menu("Reassign") {
                                                ForEach(candidates) { profile in
                                                    Button(profile.name) {
                                                        model.reassignOrchestrationJob(
                                                            attempt, in: run, to: profile
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                }
                            }
                            Text(attempt.goal).font(.system(size: 8)).lineLimit(4)
                            Text("\(attempt.role ?? "specialist") · \(attempt.state)")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                            if let provider = attempt.provider, !provider.isEmpty {
                                Text("\(provider) · \(attempt.model ?? "")")
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            if let output = attempt.output, !output.isEmpty {
                                Text(output)
                                    .font(.system(size: 8))
                                    .lineLimit(12)
                                    .textSelection(.enabled)
                            }
                            if let reasoning = attempt.reasoningText,
                               !reasoning.isEmpty,
                               model.thinkingVisibility != .hidden
                            {
                                DisclosureGroup("Reasoning") {
                                    Text(reasoning)
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.inkSoft)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 8, weight: .semibold))
                            }
                            if !attempt.evidence.isEmpty {
                                Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                                    .font(.system(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(4)
                            }
                            Text("\(attempt.elapsedMilliseconds) ms · \(attempt.promptTokens + attempt.completionTokens) tokens")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    .padding(9)
                    .background(LocusTheme.white.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(12)
        }
    }

    private func dispatchEditor(_ plan: DispatchPlan) -> some View {
        let validationErrors = model.dispatchPlanErrors(draftPlan ?? plan)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Review dispatch plan", systemImage: "checkmark.shield")
                    .font(.system(size: 11, weight: .bold))
                Text("Edit goals, assignments, and dependencies. Coding jobs must form an explicit order; Locus runs them one at a time in the shared checkout.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Plan summary", text: planBinding(\.summary))
                    if draftPlan?.budget != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("RUN BUDGET")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(LocusTheme.muted)
                            Stepper(
                                "Jobs · \(draftPlan?.budget?.maxJobs ?? 0)",
                                value: budgetBinding(\.maxJobs), in: 1...16
                            )
                            Stepper(
                                "Rounds · \(draftPlan?.budget?.maxRounds ?? 0)",
                                value: budgetBinding(\.maxRounds), in: 1...8
                            )
                            Stepper(
                                "Model calls · \(draftPlan?.budget?.maxModelCalls ?? 0)",
                                value: budgetBinding(\.maxModelCalls), in: 1...48
                            )
                            Stepper(
                                "Concurrent calls · \(draftPlan?.budget?.maxConcurrentCalls ?? 0)",
                                value: budgetBinding(\.maxConcurrentCalls), in: 1...8
                            )
                            Stepper(
                                "Hosted tokens · \(draftPlan?.budget?.maxMeteredTokens ?? 0)",
                                value: budgetBinding(\.maxMeteredTokens),
                                in: 1_000...2_000_000,
                                step: 50_000
                            )
                            TextField(
                                "Maximum estimated cost (0 disables)",
                                value: maximumCostBinding,
                                format: .number.precision(.fractionLength(0...4))
                            )
                        }
                        .font(.system(size: 8))
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(Array(plan.jobs.enumerated()), id: \.element.id) { index, job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.kind == "writer" ? "Coding" : job.kind.capitalized)
                                    .font(.system(size: 8, weight: .bold))
                                Spacer()
                                Button(role: .destructive) {
                                    draftPlan?.jobs.remove(at: index)
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain)
                            }
                            TextField("Goal", text: jobBinding(index, \.goal), axis: .vertical)
                            Picker("Agent", selection: jobBinding(index, \.agentID)) {
                                ForEach(eligibleProfiles(for: job)) { profile in
                                    Text(profile.name).tag(profile.id.uuidString)
                                }
                            }
                            TextField("Dependencies", text: dependencyBinding(index), prompt: Text("job ids, comma separated"))
                        }
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    HStack {
                        Button {
                            addJob(kind: "specialist")
                        } label: { Label("Add Specialist Job", systemImage: "plus") }
                            .buttonStyle(.borderless)
                        Button {
                            addJob(kind: "writer")
                        } label: { Label("Add Coding Job", systemImage: "hammer") }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("runs.addCodingJob")
                    }
                }
                .padding(12)
            }
            HStack {
                if let error = validationErrors.first {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.coral)
                        .lineLimit(2)
                }
                Button("Cancel") { model.decideDispatch("cancel") }
                Button("Re-dispatch") { model.decideDispatch("redispatch") }
                Spacer()
                Button("Run Plan") { model.decideDispatch("run", editedPlan: draftPlan) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!validationErrors.isEmpty)
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        }
    }

    private func eligibleProfiles(for job: DispatchJob) -> [AgentProfile] {
        guard let team = model.selectedAgentTeam else { return [] }
        return model.agentProfiles.filter { profile in
            guard team.memberIDs.contains(profile.id) else { return false }
            switch job.kind {
            case "writer":
                return profile.accessCeiling.canWrite
            case "reviewer":
                return !profile.accessCeiling.canWrite && profile.role == .reviewer
            default:
                return !profile.accessCeiling.canWrite
            }
        }
    }

    private func addJob(kind: String) {
        guard let plan = draftPlan else { return }
        let template = DispatchJob(
            id: "job-\(plan.jobs.count + 1)",
            agentID: "",
            goal: "",
            dependencies: [],
            kind: kind
        )
        guard let profile = eligibleProfiles(for: template).first else { return }
        var job = template
        job.agentID = profile.id.uuidString
        if kind == "writer",
           let priorWriter = plan.jobs.last(where: { $0.kind == "writer" })
        {
            job.dependencies = [priorWriter.id]
        }
        draftPlan?.jobs.append(job)
    }

    private var filteredEvents: [OrchestrationEvent] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let durableEvents = model.orchestrationEvents.filter { !$0.isTransientStream }
        guard !query.isEmpty else { return durableEvents }
        return durableEvents.filter { event in
            [
                event.type, event.title, event.jobID, event.attemptID,
                event.text("agent_name"), event.text("agent_id"),
                event.text("state"), event.text("provider"), event.text("model"),
                event.text("reason"),
            ]
                .compactMap { $0 }.joined(separator: " ").lowercased().contains(query)
        }
    }

    private func planBinding(_ keyPath: WritableKeyPath<DispatchPlan, String>) -> Binding<String> {
        Binding(
            get: { draftPlan?[keyPath: keyPath] ?? "" },
            set: { draftPlan?[keyPath: keyPath] = $0 }
        )
    }

    private func jobBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<DispatchJob, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index][keyPath: keyPath]
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index][keyPath: keyPath] = value
                draftPlan = plan
            }
        )
    }

    private func dependencyBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index].dependencies.joined(separator: ", ")
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index].dependencies = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                draftPlan = plan
            }
        )
    }

    private func budgetBinding(
        _ keyPath: WritableKeyPath<OrchestrationBudget, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draftPlan?.budget?[keyPath: keyPath] ?? 1 },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget[keyPath: keyPath] = value
                budget.clamp()
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private var maximumCostBinding: Binding<Double> {
        Binding(
            get: { draftPlan?.maximumEstimatedCost ?? 0 },
            set: { value in
                guard var plan = draftPlan else { return }
                plan.maximumEstimatedCost = min(max(value, 0), 100_000)
                draftPlan = plan
            }
        )
    }

    private func color(for type: String) -> Color {
        if type.contains("error") || type.contains("failed") { return LocusTheme.coral }
        if type.contains("completed") { return LocusTheme.success }
        if type.contains("waiting") || type.contains("permission") { return LocusTheme.warning }
        return LocusTheme.signalDeep
    }
}
