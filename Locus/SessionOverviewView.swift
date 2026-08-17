import Combine
import SwiftUI

struct SessionOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: SessionStateEmitter

    @AppStorage("Locus.sessionOverview.planCollapsed") private var planCollapsed = false
    @AppStorage("Locus.sessionOverview.activityCollapsed") private var activityCollapsed = false
    @AppStorage("Locus.sessionOverview.processesCollapsed") private var processesCollapsed = false
    @AppStorage("Locus.sessionOverview.filesCollapsed") private var filesCollapsed = true
    @State private var activityExpanded = false
    @State private var confirmsNewSession = false
    @State private var now = Date()

    private let timestampTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var state: SessionState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if processCount > 0 {
                        Divider().overlay(LocusTheme.line)
                        processesSection
                    }

                    if state.status == .error { errorBanner }

                    if state.status != .idle {
                        activeContent
                    }

                    Divider().overlay(LocusTheme.line)
                    quickAccessSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(LocusTheme.line)
            VStack {
                ContextWindowInfoCard()
            }
                .accessibilityIdentifier("plan.context")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(LocusTheme.paperDeep)
        .foregroundStyle(LocusTheme.ink)
        .font(.locus(size: 11))
        .onReceive(timestampTimer) { now = $0 }
        .alert("Start a new session?", isPresented: $confirmsNewSession) {
            Button("Cancel", role: .cancel) {}
            Button("New session", role: .destructive) { model.newSession() }
        } message: {
            Text("The current run is still active. Starting a new session will stop following this run here.")
        }
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: state.status)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Overview")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                Text("Session overview")
                    .font(.locus(size: 15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            statusPill
        }
    }

    private var statusPill: some View {
        let presentation: (String, Color) = switch state.status {
        case .idle: ("Idle", LocusTheme.muted)
        case .running: ("Running", LocusTheme.success)
        case .error: ("Error", LocusTheme.danger)
        }
        return HStack(spacing: 7) {
            Circle().fill(presentation.1).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(presentation.0)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(state.status == .idle ? LocusTheme.muted : presentation.1)
                .accessibilityLabel("Session status: \(presentation.0)")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("plan.status")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(
                state.status == .running
                    ? LocusTheme.successSoft
                    : state.status == .error
                        ? LocusTheme.danger.opacity(0.10)
                        : LocusTheme.white.opacity(0.72)
            )
        )
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LocusTheme.danger)
                Text(state.statusReason?.nilIfEmpty ?? "The run stopped with an error.")
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                overviewButton("Retry", symbol: "arrow.clockwise") { model.retryLastResponse() }
                overviewButton("View logs", symbol: "doc.text.magnifyingglass") {
                    model.revealSessionLogs()
                }
            }
        }
        .padding(13)
        .background(LocusTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LocusTheme.danger.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("plan.error")
    }

    @ViewBuilder
    private var activeContent: some View {
        planSection
        Divider().overlay(LocusTheme.line)
        activitySection
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionToggle(
                title: "Plan",
                detail: state.plan.isEmpty
                    ? nil : "\(state.completedStepCount) of \(state.plan.count)",
                collapsed: $planCollapsed
            )
            .accessibilityIdentifier("plan.livePlan")
            if !planCollapsed {
                if state.plan.isEmpty {
                    designedEmptyState(
                        symbol: "checklist",
                        text: "The live plan will appear as soon as the agent creates one."
                    )
                } else {
                    planRows
                }
            }
        }
    }

    @ViewBuilder
    private var planRows: some View {
        if state.plan.count > 8 {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 3) { planRowList }
                }
                .frame(maxHeight: 292)
                .onAppear { scrollToRunningStep(proxy) }
                .onChange(of: state.plan.first(where: { $0.state == .running })?.id) {
                    scrollToRunningStep(proxy)
                }
            }
        } else {
            VStack(spacing: 3) { planRowList }
        }
    }

    @ViewBuilder
    private var planRowList: some View {
        ForEach(state.plan) { step in
            SessionPlanStepRow(step: step, now: now)
                .id(step.id)
        }
    }

    private func scrollToRunningStep(_ proxy: ScrollViewProxy) {
        guard let id = state.plan.first(where: { $0.state == .running })?.id else { return }
        withAnimation(reduceMotion ? nil : LocusMotion.scroll) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionToggle(
                    title: "Activity",
                    detail: activityExpanded ? "Showing all" : nil,
                    collapsed: $activityCollapsed
                )
                .accessibilityIdentifier("plan.activity")
                if state.status == .running { runningActionsMenu }
            }
            if !activityCollapsed {
                let visible = activityExpanded
                    ? Array(state.events.reversed())
                    : Array(activityEvents.prefix(5))
                if visible.isEmpty {
                    designedEmptyState(
                        symbol: "waveform.path.ecg",
                        text: "Commands and file activity will appear here as the run progresses."
                    )
                } else {
                    if activityExpanded {
                        ScrollView {
                            activityRows(visible)
                        }
                        .frame(maxHeight: 340)
                    } else {
                        activityRows(visible)
                    }
                    if state.events.count > 5 {
                        Button(activityExpanded ? "Show recent" : "View all") {
                            activityExpanded.toggle()
                        }
                        .buttonStyle(.locus())
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                    }
                }
                filesSection
            }
        }
    }

    private func activityRows(_ events: [SessionEvent]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                SessionActivityRow(event: event, now: now) {
                    model.jumpToSessionEvent(event)
                }
            }
        }
    }

    private var activityEvents: [SessionEvent] {
        state.events.reversed().filter { event in
            switch event {
            case .fileEdit, .fileRead, .fileCreate, .command: true
            default: false
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                filesCollapsed.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: filesCollapsed ? "chevron.right" : "chevron.down")
                        .font(.locus(size: 9, weight: .semibold))
                    Text(fileSummary)
                        .font(.locus(size: 9, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(LocusTheme.inkSoft)
                .padding(.vertical, 7)
            }
            .buttonStyle(.locus())
            .accessibilityLabel(filesCollapsed ? "Expand files touched" : "Collapse files touched")
            .accessibilityIdentifier("plan.files")

            if !filesCollapsed {
                if state.files.isEmpty {
                    designedEmptyState(symbol: "doc", text: "No files touched yet.")
                } else {
                    ForEach(state.files) { file in
                        SessionFileRow(file: file) { model.openSessionFile(file.path) }
                    }
                }
            }
        }
        .padding(.top, 3)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var fileSummary: String {
        let added = state.files.reduce(0) { $0 + $1.added }
        let removed = state.files.reduce(0) { $0 + $1.removed }
        let noun = state.files.count == 1 ? "file" : "files"
        return "\(state.files.count) \(noun) · +\(added) −\(removed)"
    }

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionToggle(
                title: "Running processes",
                detail: processCount == 0 ? "None" : "\(processCount) active",
                collapsed: $processesCollapsed
            )
            .accessibilityIdentifier("plan.processes")

            if !processesCollapsed {
                VStack(spacing: 5) {
                    if showsCurrentSessionProcess {
                        currentSessionProcessRow
                    }
                    ForEach(Array(runningProcesses.prefix(3))) { run in
                        processRow(run)
                    }
                    if processCount == 0 {
                        designedEmptyState(
                            symbol: "waveform.path.ecg",
                            text: "No processes are running. Active and queued work will appear here."
                        )
                    }
                }

                Button {
                    model.openActivityCenter()
                } label: {
                    HStack(spacing: 6) {
                        Text(runningProcesses.count > 3 ? "View all processes" : "Open Activity Center")
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("plan.processes.viewAll")
            }
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Quick Access")
                .font(.locus(size: 11, weight: .bold))
                .foregroundStyle(LocusTheme.muted)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78), spacing: 8)],
                spacing: 8
            ) {
                quickAccessButton("Agents", symbol: "person.3") {
                    model.settingsPage = .agents
                    model.settingsPresented = true
                }
                quickAccessButton("Skills & MCP", symbol: "puzzlepiece.extension") {
                    model.settingsPage = .extensions
                    model.settingsPresented = true
                }
                quickAccessButton("Browser", symbol: "globe") {
                    model.selectInspectorTab(.preview)
                }
                quickAccessButton("Files", symbol: "folder") {
                    model.selectInspectorTab(.files)
                }
                quickAccessButton("Changes", symbol: "plusminus.circle") {
                    model.selectInspectorTab(.changes)
                }
                quickAccessButton("Terminal", symbol: "terminal") {
                    model.openTerminal()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Access")
        .accessibilityIdentifier("plan.quickActions")
    }

    private func quickAccessButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.locus(size: 17, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.locus(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(LocusTheme.inkSoft)
            .frame(maxWidth: .infinity, minHeight: 62)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.locus(.card))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(
            "plan.quickAction."
                + title.lowercased()
                    .replacingOccurrences(of: " & mcp", with: "")
                    .replacingOccurrences(of: " ", with: "-")
        )
    }

    private var activeProcessStates: Set<String> {
        [
            "queued", "running", "dispatching", "reviewing", "paused",
            "waiting_permission", "waiting_computer", "waiting_dispatch_approval",
        ]
    }

    private var runningProcesses: [OrchestrationRun] {
        model.visibleActivityRuns
            .filter { activeProcessStates.contains($0.state) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var showsCurrentSessionProcess: Bool {
        state.status == .running
            && !runningProcesses.contains { $0.sessionID == model.currentSessionID }
    }

    private var processCount: Int {
        runningProcesses.count + (showsCurrentSessionProcess ? 1 : 0)
    }

    private var currentSessionProcessRow: some View {
        Button { model.openActivityCenter() } label: {
            processLabel(
                title: model.currentWorkPhase.nilIfEmpty ?? "Current session",
                detail: "RUNNING · this chat",
                color: LocusTheme.success,
                elapsed: nil
            )
        }
        .buttonStyle(.locus(.card))
        .accessibilityLabel("Current session process, running")
        .accessibilityIdentifier("plan.process.current")
    }

    private func processRow(_ run: OrchestrationRun) -> some View {
        Button {
            model.selectInspectorTab(.runs, selecting: run.id)
        } label: {
            processLabel(
                title: run.request.nilIfEmpty ?? run.teamName?.nilIfEmpty ?? "Background task",
                detail: processStateTitle(run.state),
                color: processColor(run.state),
                elapsed: processElapsed(run)
            )
        }
        .buttonStyle(.locus(.card))
        .accessibilityLabel(
            "\(run.request.nilIfEmpty ?? run.teamName?.nilIfEmpty ?? "Background task"), "
                + "\(processStateTitle(run.state)), \(processElapsed(run))"
        )
        .accessibilityIdentifier("plan.process.\(run.id)")
    }

    private func processLabel(
        title: String,
        detail: String,
        color: Color,
        elapsed: String?
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.locus(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let elapsed {
                Text(elapsed)
                    .font(.locus(size: 8.5, design: .monospaced))
                    .foregroundStyle(LocusTheme.inkSoft)
            }
            Image(systemName: "chevron.right")
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func processStateTitle(_ state: String) -> String {
        switch state {
        case "waiting_permission": "NEEDS PERMISSION"
        case "waiting_computer": "WAITING FOR COMPUTER"
        case "waiting_dispatch_approval": "PLAN READY"
        default: state.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private func processColor(_ state: String) -> Color {
        switch state {
        case "running", "dispatching", "reviewing": LocusTheme.success
        case "queued", "paused", "waiting_permission", "waiting_computer",
             "waiting_dispatch_approval": LocusTheme.warning
        default: LocusTheme.muted
        }
    }

    private func processElapsed(_ run: OrchestrationRun) -> String {
        let seconds = max(Int(now.timeIntervalSince1970 - run.createdAt), 0)
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private var runningActionsMenu: some View {
        Menu {
            Button("Finder", systemImage: "folder") { model.revealSessionWorkspace() }
            Button("Proxy config", systemImage: "slider.horizontal.3") {
                model.revealSessionProxyConfig()
            }
            Button("Logs", systemImage: "doc.text") { model.revealSessionLogs() }
            Divider()
            Button("New session", systemImage: "plus") { requestNewSession() }
            Button("Copy session summary", systemImage: "doc.on.doc") {
                model.copySessionOverview()
            }
            Button("Clear context", systemImage: "eraser") {
                model.clearSessionOverviewContext()
            }
            Button("Settings", systemImage: "gearshape") { model.openSessionModelSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(LocusTheme.white.opacity(0.72))
                .clipShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Session actions")
        .accessibilityIdentifier("plan.runningActions")
    }

    private func requestNewSession() {
        if state.status == .running { confirmsNewSession = true } else { model.newSession() }
    }

    private func sectionToggle(
        title: String,
        detail: String?,
        collapsed: Binding<Bool>
    ) -> some View {
        Button { collapsed.wrappedValue.toggle() } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.locus(size: 9, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                }
                Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(collapsed.wrappedValue ? "Expand" : "Collapse") \(title)")
    }

    private func overviewButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 9, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LocusTheme.white.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.locus())
    }

    private func designedEmptyState(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionPlanStepRow: View {
    let step: SessionPlanStep
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            stepIcon.frame(width: 17)
            Text(step.label)
                .font(.locus(size: 10, weight: step.state == .running ? .semibold : .regular))
                .strikethrough(step.state == .done)
                .foregroundStyle(labelColor)
                .lineLimit(2)
            Spacer(minLength: 8)
            if step.state == .running, let started = step.startedAt {
                Text(elapsed(from: started))
                    .font(.locus(size: 8.5, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(step.state == .running ? LocusTheme.successSoft : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(LocusTheme.success)
        case .running:
            ProgressView().controlSize(.small).tint(LocusTheme.signalDeep)
        case .pending:
            Image(systemName: "circle").foregroundStyle(LocusTheme.muted)
        case .failed:
            Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(LocusTheme.danger)
        }
    }

    private var labelColor: Color {
        switch step.state {
        case .done: LocusTheme.muted
        case .running: LocusTheme.ink
        case .pending: LocusTheme.inkSoft
        case .failed: LocusTheme.danger
        }
    }

    private func elapsed(from milliseconds: Int) -> String {
        let seconds = max(Int(now.timeIntervalSince1970) - milliseconds / 1_000, 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct SessionActivityRow: View {
    let event: SessionEvent
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.locus(size: 9, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(subject)
                    .font(.locus(size: 9.5, design: .monospaced))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 5)
                metadata
                Text(relativeTime)
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(subject), \(relativeTime)")
    }

    private var icon: String {
        switch event {
        case .fileEdit: "pencil"
        case .fileRead: "doc.text"
        case .fileCreate: "doc.badge.plus"
        case .command: "terminal"
        case .message: "bubble.left"
        case .planCreated, .stepState: "checklist"
        case .tokens: "gauge.with.dots.needle.bottom.50percent"
        case .status: "circle.dotted"
        case .runFinished: "flag.checkered"
        }
    }

    private var iconColor: Color {
        switch event {
        case .command(_, let code, _) where code != nil && code != 0: LocusTheme.danger
        case .status(let status, _, _) where status == .error: LocusTheme.danger
        default: LocusTheme.muted
        }
    }

    private var subject: String {
        switch event {
        case .fileEdit(let path, _, _, _), .fileRead(let path, _), .fileCreate(let path, _): path
        case .command(let command, _, _): command
        case .message(let role, _): role == .user ? "User message" : "Assistant message"
        case .planCreated(let steps, _): "Plan created (\(steps.count) steps)"
        case .stepState(let id, let state, _): "\(id) · \(state.rawValue)"
        case .tokens: "Context updated"
        case .status(let status, _, _): "Status · \(status.rawValue)"
        case .runFinished(let summary, _, _): summary.summary
        }
    }

    @ViewBuilder
    private var metadata: some View {
        switch event {
        case .fileEdit(_, let added, let removed, _):
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(LocusTheme.success)
                Text("−\(removed)").foregroundStyle(LocusTheme.danger)
            }
            .font(.locus(size: 8.5, design: .monospaced))
        case .fileRead:
            Text("read").foregroundStyle(LocusTheme.muted)
                .font(.locus(size: 8.5))
        case .fileCreate:
            Text("created").foregroundStyle(LocusTheme.success)
                .font(.locus(size: 8.5))
        case .command(_, let code, _):
            if let code, code != 0 {
                Text("\(code) failed").foregroundStyle(LocusTheme.danger)
                    .font(.locus(size: 8.5))
            }
        default:
            EmptyView()
        }
    }

    private var relativeTime: String {
        let elapsed = max(Int(now.timeIntervalSince1970) - event.timestamp / 1_000, 0)
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3_600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3_600)h"
    }
}

private struct SessionFileRow: View {
    let file: SessionFileTouch
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: file.kind == .create ? "doc.badge.plus" : "doc.text")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                Text(file.path)
                    .font(.locus(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("+\(file.added)").foregroundStyle(LocusTheme.success)
                Text("−\(file.removed)").foregroundStyle(LocusTheme.danger)
            }
            .font(.locus(size: 8.5, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .buttonStyle(.locus())
        .help(file.path)
    }
}
