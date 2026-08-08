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
    @State private var viewMode = "overview"
    @State private var filter = ""
    @State private var draftPlan: DispatchPlan?
    @State private var showTechnicalLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let plan = draftPlan, model.pendingDispatchPlan != nil {
                dispatchEditor(plan)
            } else if let run = model.selectedOrchestrationRun {
                runBody(run)
            } else {
                InspectorPlaceholder(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No team run selected",
                    message: "Team Runs shows each plan, model assignment, live progress, result, and any available recovery action.",
                    identifier: "runs.empty"
                )
            }
        }
        .task(id: model.currentSessionID) {
            if !model.isLoadingOrchestrationRuns {
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
                Text("TEAM RUNS")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Button {
                    Task { await model.refreshOrchestrationRuns() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh run history")
            }
            if !runPickerRuns.isEmpty || model.isLoadingOrchestrationRuns {
                Picker("Run", selection: Binding(
                    get: { model.selectedOrchestrationRun?.id },
                    set: { id in
                        guard let id else { return }
                        Task { await model.loadOrchestrationRun(id) }
                    }
                )) {
                    Text(model.isLoadingOrchestrationRuns ? "Loading team runs…" : "Select a run")
                        .tag(nil as String?)
                    ForEach(runPickerRuns) { run in
                        Text("\(run.teamName ?? "Team") · \(run.state.replacingOccurrences(of: "_", with: " "))")
                            .tag(Optional(run.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("runs.picker")
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var runPickerRuns: [OrchestrationRun] {
        AppModel.orchestrationPickerRuns(
            model.orchestrationRuns,
            selected: model.selectedOrchestrationRun
        )
    }

    private func runBody(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            runSummary(run)
            Picker("View", selection: $viewMode) {
                Text("Overview").tag("overview")
                Text("Activity").tag("activity")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if viewMode == "overview" { overview(run) } else { activity(run) }
        }
    }

    private func runSummary(_ run: OrchestrationRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.teamName ?? "Team run").font(.system(size: 11, weight: .bold))
                    Text(runStateTitle(run))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("runs.state")
                }
                Spacer()
                runActions(run)
            }
            let presentation = model.teamRunPresentation(for: run.id, durable: run)
            if let reason = run.recoveryReason, presentation.canRecover {
                Label(reason, systemImage: "arrow.clockwise.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
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
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        Menu {
            Button(run.pinned ? "Unpin Run" : "Pin Run") {
                model.setOrchestrationPinned(run, pinned: !run.pinned)
            }
            if presentation.canRecover {
                Button("Resume") { model.resumeOrchestration(run) }
            }
            if run.taskID != nil && !run.legacy {
                Button("Replay Same Baseline") { model.replayOrchestration(run) }
            }
            if !run.legacy {
                Button("Duplicate from Current Workspace") { model.duplicateOrchestration(run) }
            }
            if presentation.canPause {
                Button("Pause at Safe Boundary") { model.pauseOrchestration(run.id) }
            }
            if presentation.canStop {
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
                .disabled(
                    presentation.isActivelyOwned
                        || (!presentation.state.isTerminal && !presentation.canRecover)
                )
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

    private func overview(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCard("REQUEST", symbol: "text.bubble") {
                    Text(run.request.isEmpty ? "No request was recorded." : run.request)
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(8)
                }

                overviewCard("PROGRESS", symbol: "chart.bar.fill") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(runPhases(run).enumerated()), id: \.offset) { index, phase in
                            HStack(spacing: 8) {
                                Image(systemName: phase.done
                                    ? "checkmark.circle.fill"
                                    : phase.active ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(phase.done
                                        ? LocusTheme.success
                                        : phase.active ? LocusTheme.signalDeep : LocusTheme.lineStrong)
                                    .frame(width: 13)
                                Text(phase.title)
                                    .font(.system(size: 9, weight: phase.active ? .bold : .regular))
                                Spacer()
                                if phase.active {
                                    Text("Current")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(LocusTheme.signalDeep)
                                }
                            }
                            if index < runPhases(run).count - 1 {
                                Rectangle().fill(phase.done ? LocusTheme.success.opacity(0.4) : LocusTheme.line)
                                    .frame(width: 1, height: 7)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }

                if let jobs = run.plan?.jobs, !jobs.isEmpty {
                    overviewCard("PLAN AND ASSIGNMENTS", symbol: "list.bullet.clipboard") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let summary = run.plan?.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                                let attempt = run.attempts?.last(where: { $0.jobID == job.id })
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text("\(index + 1). \(friendlyJobKind(job.kind))")
                                            .font(.system(size: 8, weight: .bold))
                                        Text("· \(attempt?.agentName ?? job.agentID)")
                                            .font(.system(size: 8))
                                            .foregroundStyle(LocusTheme.muted)
                                    }
                                    Text(job.goal)
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.inkSoft)
                                        .lineLimit(4)
                                    if let provider = attempt?.provider, !provider.isEmpty {
                                        Text("\(provider) · \(attempt?.model ?? "")")
                                            .font(.system(size: 7, design: .monospaced))
                                            .foregroundStyle(LocusTheme.muted)
                                    }
                                    if !job.dependencies.isEmpty {
                                        Text("Runs after: \(job.dependencies.joined(separator: ", "))")
                                            .font(.system(size: 7))
                                            .foregroundStyle(LocusTheme.muted)
                                    }
                                }
                            }
                        }
                    }
                }

                if let attempts = run.attempts, !attempts.isEmpty {
                    overviewCard("JOB RESULTS", symbol: "person.3.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(attempts) { attempt in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Image(systemName: attempt.state == "completed"
                                            ? "checkmark.circle.fill"
                                            : attempt.state == "paused" ? "pause.circle.fill" : "circle.dotted")
                                            .foregroundStyle(attempt.state == "completed"
                                                ? LocusTheme.success
                                                : attempt.state == "paused" ? LocusTheme.warning : LocusTheme.signalDeep)
                                        Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                                            .font(.system(size: 8, weight: .bold))
                                        Text(attempt.state.replacingOccurrences(of: "_", with: " "))
                                            .font(.system(size: 7, design: .monospaced))
                                            .foregroundStyle(LocusTheme.muted)
                                        Spacer()
                                        if model.teamRunPresentation(
                                            for: run.id, durable: run
                                        ).canRecover,
                                           attempt.state != "running"
                                            && !model.isCodingAttempt(attempt, in: run) {
                                            Menu {
                                                Button("Retry with Same Agent") {
                                                    model.retryOrchestrationJob(attempt, in: run)
                                                }
                                                let candidates = model.reassignmentCandidates(for: attempt, in: run)
                                                if !candidates.isEmpty {
                                                    Menu("Reassign") {
                                                        ForEach(candidates) { profile in
                                                            Button(profile.name) {
                                                                model.reassignOrchestrationJob(attempt, in: run, to: profile)
                                                            }
                                                        }
                                                    }
                                                }
                                            } label: { Image(systemName: "arrow.clockwise.circle") }
                                                .menuStyle(.borderlessButton)
                                                .menuIndicator(.hidden)
                                        }
                                    }
                                    if let output = attempt.output, !output.isEmpty {
                                        Text(output)
                                            .font(.system(size: 8))
                                            .foregroundStyle(LocusTheme.inkSoft)
                                            .lineLimit(5)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }

                overviewCard("RESULTS", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Jobs", "\(run.completedJobCount ?? 0) of \(run.jobCount ?? 0) completed")
                        metricRow("Duration", runDuration(run))
                        if let calls = run.usage?["model_calls"]?.integer {
                            metricRow("Model calls", calls.formatted())
                        }
                        if run.id == model.orchestrationRunID, !model.gitChanges.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Changed files")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                                ForEach(model.gitChanges.prefix(8)) { change in
                                    Text("\(change.status.marker)  \(change.path)")
                                        .font(.system(size: 7, design: .monospaced))
                                        .lineLimit(1)
                                }
                                if model.gitChanges.count > 8 {
                                    Text("+ \(model.gitChanges.count - 8) more")
                                        .font(.system(size: 7))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                        }
                        let presentation = model.teamRunPresentation(for: run.id, durable: run)
                        if let reason = run.recoveryReason,
                           !reason.isEmpty,
                           presentation.canRecover || presentation.state.isTerminal
                        {
                            Label(reason, systemImage: presentation.canRecover
                                ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(presentation.canRecover
                                    ? LocusTheme.warning : LocusTheme.coral)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Run ID · \(run.id)")
                        Text("Saved events · \(run.lastSequence)")
                        if let checkpoint = run.checkpoint {
                            Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " "))")
                        }
                    }
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.top, 6)
                }
                .font(.system(size: 8, weight: .semibold))
            }
            .padding(12)
        }
        .accessibilityIdentifier("runs.overview")
    }

    private func activity(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter team activity", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                Toggle("Technical log", isOn: $showTechnicalLog)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.technicalLog")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
            if showTechnicalLog {
                timeline(run, showsFilter: false)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(activityGroups) { group in
                            Text(group.title.uppercased())
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(LocusTheme.muted)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.events) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: friendlyEventSymbol(event))
                                        .foregroundStyle(color(for: event.type))
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friendlyEventTitle(event))
                                            .font(.system(size: 9, weight: .semibold))
                                        Text(friendlyEventDetail(event))
                                            .font(.system(size: 8))
                                            .foregroundStyle(LocusTheme.inkSoft)
                                            .lineLimit(6)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("runs.activity")
    }

    private func overviewCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.muted)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.white.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(LocusTheme.muted)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 8))
    }

    private func timeline(_ run: OrchestrationRun, showsFilter: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsFilter {
                TextField("Filter agent, event, state, or attempt", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
            }
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
                                if model.teamRunPresentation(
                                    for: run.id, durable: run
                                ).canRecover,
                                   attempt.state != "running"
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
                            Picker("Call budget", selection: callBudgetModeBinding) {
                                ForEach(OrchestrationBudget.CallBudgetMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            if draftPlan?.budget?.callBudgetMode == .fixed {
                                Stepper(
                                    "Model calls · \(draftPlan?.budget?.maxModelCalls ?? 0)",
                                    value: budgetBinding(\.maxModelCalls), in: 1...100
                                )
                            }
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

    private var callBudgetModeBinding: Binding<OrchestrationBudget.CallBudgetMode> {
        Binding(
            get: { draftPlan?.budget?.callBudgetMode ?? .fixed },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget.callBudgetMode = value
                if value == .automatic { budget.maxModelCalls = 100 }
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private struct RunPhase {
        let title: String
        let done: Bool
        let active: Bool
    }

    private struct ActivityGroup: Identifiable {
        let title: String
        let events: [OrchestrationEvent]
        var id: String { title }
    }

    private var activityGroups: [ActivityGroup] {
        let visible = filteredEvents.filter(isUserFacingEvent)
        let order = ["Planning", "Approval", "Specialists", "Coding jobs", "Review", "Complete"]
        let grouped = Dictionary(grouping: visible, by: activityPhase)
        return order.compactMap { title in
            guard let events = grouped[title], !events.isEmpty else { return nil }
            return ActivityGroup(title: title, events: events)
        }
    }

    private func runPhases(_ run: OrchestrationRun) -> [RunPhase] {
        let state = model.teamRunPresentation(for: run.id, durable: run).state
        let current: Int = switch state {
        case .queued, .dispatching: 0
        case .waitingDispatchApproval: 1
        case .running, .waitingPermission, .waitingComputer:
            (run.attempts ?? []).contains { model.isCodingAttempt($0, in: run) } ? 3 : 2
        case .reviewing: 4
        case .completed: 5
        case .paused, .failed, .interrupted, .cancelled, .discarded:
            phaseIndex(for: run)
        }
        return ["Planning", "Plan approval", "Specialists", "Coding jobs", "Review", "Complete"]
            .enumerated().map { index, title in
                RunPhase(
                    title: title,
                    done: state == .completed || index < current,
                    active: state != .completed && index == current
                )
            }
    }

    private func phaseIndex(for run: OrchestrationRun) -> Int {
        let kind = run.checkpoint?.kind.lowercased() ?? ""
        if kind.contains("synthesis") { return 5 }
        if kind.contains("review") || kind.contains("revision") { return 4 }
        if kind.contains("writer") { return 3 }
        if kind.contains("dispatch") { return 2 }
        return run.plan == nil ? 0 : 2
    }

    private func runStateTitle(_ run: OrchestrationRun) -> String {
        let state = model.teamRunPresentation(for: run.id, durable: run).state.title
        let total = run.jobCount ?? 0
        guard total > 0 else { return state }
        return "\(state) · \(run.completedJobCount ?? 0) of \(total) jobs"
    }

    private func runDuration(_ run: OrchestrationRun) -> String {
        let end = run.completedAt ?? run.updatedAt
        let seconds = max(Int(end - run.createdAt), 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func friendlyJobKind(_ kind: String) -> String {
        switch kind {
        case "writer": "Coding job"
        case "reviewer": "Review"
        default: "Specialist"
        }
    }

    private func isUserFacingEvent(_ event: OrchestrationEvent) -> Bool {
        event.type == "error"
            || event.type == "permission_request"
            || event.type == "dispatch_plan_ready"
            || event.type == "dispatcher_plan_rejected"
            || event.type == "task_changes"
            || event.type.hasPrefix("agent_job_")
            || event.type.hasPrefix("orchestration_")
    }

    private func activityPhase(_ event: OrchestrationEvent) -> String {
        switch event.type {
        case "dispatch_plan_ready", "dispatch_plan", "dispatch_decision":
            return "Approval"
        case "dispatcher_plan_rejected":
            return "Planning"
        case "task_changes", "orchestration_completed":
            return "Complete"
        case "permission_request", "agent_job_continuing", "agent_job_incomplete":
            return "Coding jobs"
        case "agent_job_started", "agent_job_completed":
            if event.text("writer_position") != nil || event.text("writer_job_id") != nil {
                return "Coding jobs"
            }
            if event.text("role")?.lowercased() == "reviewer" {
                return "Review"
            }
            return "Specialists"
        case "orchestration_state":
            return event.text("state") == "reviewing" ? "Review" : "Planning"
        case "error", "orchestration_paused":
            return model.orchestrationState == .reviewing ? "Review" : "Coding jobs"
        default:
            return "Planning"
        }
    }

    private func friendlyEventTitle(_ event: OrchestrationEvent) -> String {
        switch event.type {
        case "orchestration_started": "Team run started"
        case "orchestration_state": event.text("state") == "reviewing" ? "Review started" : "Team progressed"
        case "dispatch_plan_ready": "Plan ready for your approval"
        case "dispatcher_plan_rejected": "Correcting dispatcher plan"
        case "agent_job_started": event.text("writer_position").map {
            "Coding job \($0) started"
        } ?? "Specialist started"
        case "agent_job_continuing": "Coding job is continuing"
        case "agent_job_incomplete": "Coding job needs more capacity"
        case "agent_job_completed": "Job completed"
        case "permission_request": "Waiting for permission"
        case "orchestration_paused": "Run paused safely"
        case "orchestration_completed": event.text("state") == "completed"
            ? "Team run completed" : "Team run stopped"
        case "task_changes": "Workspace changes are ready"
        case "error": "Run error"
        default: event.title
        }
    }

    private func friendlyEventDetail(_ event: OrchestrationEvent) -> String {
        let agent = event.text("agent_name")
        let model = event.text("model")
        let route = [agent, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return event.text("message")?.nilIfEmpty
            ?? event.text("reason")?.nilIfEmpty
            ?? event.detail?.nilIfEmpty
            ?? route.nilIfEmpty
            ?? event.title
    }

    private func friendlyEventSymbol(_ event: OrchestrationEvent) -> String {
        if event.type.contains("completed") { return "checkmark.circle.fill" }
        if event.type.contains("incomplete") || event.type.contains("paused") { return "pause.circle.fill" }
        if event.type.contains("error") || event.type.contains("rejected") { return "exclamationmark.circle.fill" }
        if event.type.contains("permission") { return "lock.circle.fill" }
        if event.type.contains("plan") { return "list.bullet.clipboard.fill" }
        return "circle.inset.filled"
    }

    private func color(for type: String) -> Color {
        if type.contains("error") || type.contains("failed") { return LocusTheme.coral }
        if type.contains("completed") { return LocusTheme.success }
        if type.contains("waiting") || type.contains("permission") { return LocusTheme.warning }
        return LocusTheme.signalDeep
    }
}
