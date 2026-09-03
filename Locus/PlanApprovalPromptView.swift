import SwiftUI

/// A deliberately small inline view of temporary Solo workers. It appears only
/// after the root delegates and has no team controls or writer UI. Any inherited
/// tool approval still appears in the normal composer permission panel.
struct SoloSwarmPanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    let runID: String

    var body: some View {
        Group {
            if hasDelegation {
                if isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        panel(now: timeline.date, compact: false)
                    }
                } else {
                    panel(now: Date(), compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("soloSwarmPanel.\(runID)")
    }

    private func panel(now: Date, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 8) {
                Image(systemName: isSuccessful ? "checkmark.circle.fill" : "circle.hexagongrid.fill")
                    .foregroundStyle(isSuccessful ? LocusTheme.success : LocusTheme.signalDeep)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SOLO WORKERS")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text(summaryText(now: now))
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                }
                Spacer()
                if modelCalls > 0 || delegatedTokens > 0 {
                    Text("\(modelCalls) calls · \(delegatedTokens.formatted()) tok")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            if !compact {
                Divider()
                ForEach(liveActivities) { activity in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: activity.state == .completed
                            ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(activity.state == .completed
                                ? LocusTheme.success : LocusTheme.signalDeep)
                            .frame(width: 13)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.agentName)
                                .font(.locus(size: 9, weight: .semibold))
                            Text(activity.goal)
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(2)
                            Text([activity.provider, activity.model,
                                  activity.executionEngine.replacingOccurrences(of: "_", with: " ")]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(10)
        .locusCard(radius: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.28), lineWidth: 1)
        }
    }

    private var run: OrchestrationRun? { model.runRecord(for: runID) }
    private var isActive: Bool { model.orchestrationRunID == runID && model.isBusy }
    private var liveActivities: [AgentActivity] {
        guard model.orchestrationRunID == runID else { return [] }
        return teamRunLive.agentActivities.filter { $0.depth == 1 }
    }
    private var attempts: [AgentJobAttempt] { run?.attempts ?? [] }
    private var hasDelegation: Bool {
        !liveActivities.isEmpty || !attempts.isEmpty || (run?.jobCount ?? 0) > 0
    }
    private var workerCount: Int {
        if !liveActivities.isEmpty { return Set(liveActivities.map(\.id)).count }
        return Set(attempts.map(\.jobID)).count
    }
    private var completedCount: Int {
        if !liveActivities.isEmpty {
            return liveActivities.filter { $0.state == .completed }.count
        }
        return attempts.filter { $0.state == "completed" }.count
    }
    private var modelCalls: Int {
        if !liveActivities.isEmpty { return teamRunLive.teamModelCalls }
        return attempts.reduce(0) { $0 + $1.modelCalls }
    }
    private var delegatedTokens: Int {
        if !liveActivities.isEmpty { return teamRunLive.teamMeteredTokens }
        return attempts.reduce(0) { $0 + $1.promptTokens + $1.completionTokens }
    }
    private var isSuccessful: Bool {
        !isActive && workerCount > 0 && completedCount == workerCount
    }

    private func summaryText(now: Date) -> String {
        let progress = isActive
            ? "\(completedCount)/\(workerCount) workers"
            : "\(workerCount) workers · \(completedCount) completed"
        let elapsed: TimeInterval
        if isActive, let started = liveActivities.compactMap(\.startedAt).min() {
            elapsed = max(now.timeIntervalSince(started), 0)
        } else if let run {
            elapsed = max((run.completedAt ?? run.updatedAt) - run.createdAt, 0)
        } else {
            elapsed = 0
        }
        let seconds = Int(elapsed)
        return "\(progress) · \(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")"
    }
}

/// A durable, user-facing representation of one team run. It is rendered in
/// the conversation directly below the request carrying the same run id, so
/// planning and execution never displace the message composer.
struct TeamRunBoardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
    let runID: String
    let request: String

    @State private var terminalExpanded = false

    var body: some View {
        Group {
            if isActive, teamRunLive.shouldShowTeamDispatchProgress {
                TeamDispatchProgressView()
            } else if isActive, teamRunLive.shouldShowTeamDispatchApproval,
                      let plan = teamRunLive.pendingDispatchPlan
            {
                TeamDispatchApprovalPromptView(plan: plan)
            } else if shouldCollapseTerminal, !terminalExpanded {
                compactTerminal
            } else if isActive, state != .paused, !state.isTerminal {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    board(now: timeline.date)
                }
            } else {
                board(now: Date())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teamBoard.\(runID)")
    }

    private func board(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            boardHeader(now: now)
            Divider()
            phaseRail
                .padding(12)
            if !visibleActivities.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("TEAM JOBS")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(LocusTheme.muted)
                    ForEach(visibleActivities) { activity in
                        activityRow(activity, now: now)
                    }
                }
                .padding(12)
            }
            if let explanation = statusExplanation {
                Divider()
                Label(explanation, systemImage: state == .paused
                    ? "pause.circle.fill" : "info.circle.fill")
                    .font(.locus(size: 9))
                    .foregroundStyle(state == .paused ? LocusTheme.warning : LocusTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
            Divider()
            actionRow
                .padding(12)
        }
        .locusCard(radius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(stateColor.opacity(0.45), lineWidth: 1)
        }
    }

    private var compactTerminal: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(LocusMotion.spatial) { terminalExpanded = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(teamName).font(.locus(size: 10, weight: .bold))
                            Text(state.title)
                                .font(.locus(size: 8, weight: .semibold))
                                .foregroundStyle(stateColor)
                        }
                        Text(terminalSummary)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("Expand")
                        .font(.locus(size: 8, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.locus(size: 8, weight: .bold))
                }
                .foregroundStyle(LocusTheme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("\(teamName), \(state.title). \(terminalSummary). Expand")
            .accessibilityIdentifier("teamBoard.terminalSummary")
            Button("Open Team Runs") { model.openTeamRun(runID) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("teamBoard.openRuns")
        }
        .padding(12)
        .locusCard(radius: 10)
        .accessibilityElement(children: .contain)
    }

    private func boardHeader(now: Date) -> some View {
        HStack(spacing: 9) {
            Image(systemName: stateSymbol)
                .font(.locus(size: 13, weight: .semibold))
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("TEAM RUN")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                Text(teamName).font(.locus(size: 12, weight: .bold))
            }
            Spacer()
            if isActive, teamRunLive.teamModelCalls > 0 || teamRunLive.teamMeteredTokens > 0 {
                Text("\(teamRunLive.teamModelCalls) calls · \(teamRunLive.teamMeteredTokens.formatted()) tokens")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            if isActive, let startedAt = model.activeWorkStartedAt {
                Text(elapsedText(max(now.timeIntervalSince(startedAt), 0)))
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            Text(state.title)
                .font(.locus(size: 8, weight: .bold))
                .foregroundStyle(stateColor)
            if state.isTerminal {
                Button {
                    withAnimation(LocusMotion.spatial) { terminalExpanded = false }
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.locus())
                    .accessibilityLabel("Collapse team result")
            }
        }
        .padding(12)
    }

    private var phaseRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(3)
            HStack(spacing: 5) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                    HStack(spacing: 4) {
                        Image(systemName: phaseSymbol(index))
                            .font(.locus(size: 8, weight: .bold))
                            .foregroundStyle(phaseColor(index))
                        Text(phase)
                            .font(.locus(size: 7, weight: index == currentPhase ? .bold : .regular))
                            .foregroundStyle(index <= currentPhase ? LocusTheme.inkSoft : LocusTheme.muted)
                            .lineLimit(1)
                        if index < phases.count - 1 {
                            Rectangle().fill(index < currentPhase ? LocusTheme.success : LocusTheme.line)
                                .frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ activity: AgentActivity, now: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if activity.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.leading, CGFloat((activity.depth - 1) * 12))
            }
            Image(systemName: activity.state == .completed
                ? "checkmark.circle.fill"
                : activity.state == .paused ? "pause.circle.fill" : "circle.dotted")
                .foregroundStyle(activity.state == .completed
                    ? LocusTheme.success
                    : activity.state == .paused ? LocusTheme.warning : LocusTheme.signalDeep)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(activity.writerPosition.map {
                        "Coding job \($0) of \(activity.writerTotal ?? 1)"
                    } ?? activity.agentName)
                        .font(.locus(size: 9, weight: .semibold))
                    if activity.writerPosition != nil {
                        Text("· \(activity.agentName)")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                Text([activity.provider, activity.model,
                      activity.executionEngine.replacingOccurrences(of: "_", with: " ")]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                Text(activity.output.isEmpty ? activity.goal : activity.output)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if let startedAt = activity.startedAt {
                let seconds = activity.state == .running
                    ? max(now.timeIntervalSince(startedAt), 0)
                    : Double(activity.elapsedMilliseconds) / 1_000
                Text(elapsedText(seconds))
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
        }
        .accessibilityIdentifier("teamBoard.agentTree.\(activity.nodeID ?? activity.id)")
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    private var actionRow: some View {
        HStack(spacing: 9) {
            if presentation.canRecover, let run {
                if run.checkpoint?.state["fallback_action"]?.string == "run_with_locus" {
                    Button("Run with Locus") { model.runOrchestrationWithLocus(run) }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        .accessibilityIdentifier("teamBoard.runWithLocus")
                } else {
                    Button("Resume") { model.resumeOrchestration(run) }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        .accessibilityIdentifier("teamBoard.resume")
                }
                Button("Discard", role: .destructive) { model.discardOrchestration(run.id) }
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("teamBoard.discard")
            } else if let activeID = model.orchestrationRunID {
                if presentation.canPause {
                    Button("Pause at Safe Boundary") { model.pauseOrchestration(activeID) }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("teamBoard.pause")
                }
                if presentation.canStop {
                    Button("Stop", role: .destructive) { model.cancelOrchestration(activeID) }
                        .buttonStyle(.locus())
                        .foregroundStyle(LocusTheme.coral)
                        .accessibilityIdentifier("teamBoard.stop")
                }
            }
            if state == .completed, landingFlow.taskHasChanges, isActive {
                Button("Review & Land") { landingFlow.prepareReviewAndLand() }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
            }
            Spacer()
            Button("Open Team Runs") { model.openTeamRun(runID) }
                .buttonStyle(.locus())
                .accessibilityIdentifier("teamBoard.openRuns")
        }
        .font(.locus(size: 9, weight: .semibold))
    }

    private var run: OrchestrationRun? {
        if runs.selectedOrchestrationRun?.id == runID { return runs.selectedOrchestrationRun }
        return runs.orchestrationRuns.first(where: { $0.id == runID })
    }

    private var presentation: TeamRunPresentation {
        model.teamRunPresentation(for: runID, durable: run)
    }
    private var isActive: Bool { presentation.isCurrent }
    private var shouldCollapseTerminal: Bool {
        presentation.shouldCollapseTerminal
    }
    private var state: TeamRunState {
        presentation.state
    }
    private var teamName: String {
        if isActive, let name = teamRunLive.activeOrchestrationTeam?.name { return name }
        return run?.teamName ?? "Team run"
    }
    private var visibleActivities: [AgentActivity] {
        guard isActive else { return [] }
        return teamRunLive.agentActivities
    }
    private var phases: [String] { ["Plan", "Approve", "Specialists", "Coding", "Review", "Done"] }
    private var currentPhase: Int {
        return switch state {
        case .queued, .dispatching: 0
        case .waitingDispatchApproval: 1
        case .running, .waitingPermission, .waitingComputer:
            teamRunLive.agentActivities.contains(where: { $0.writerPosition != nil }) ? 3 : 2
        case .reviewing: 4
        case .completed: 5
        case .paused, .failed, .interrupted, .cancelled, .discarded: interruptedPhase
        }
    }
    private var interruptedPhase: Int {
        if teamRunLive.pendingDispatchPlan != nil { return 1 }
        if visibleActivities.contains(where: { $0.writerPosition != nil }) { return 3 }
        if let kind = run?.checkpoint?.kind.lowercased() {
            if kind.contains("synthesis") { return 5 }
            if kind.contains("review") || kind.contains("revision") { return 4 }
            if kind.contains("writer") { return 3 }
            if kind.contains("dispatch") { return 2 }
        }
        return run?.plan == nil ? 0 : 2
    }
    private func phaseSymbol(_ index: Int) -> String {
        index < currentPhase || state == .completed ? "checkmark.circle.fill"
            : index == currentPhase ? "circle.inset.filled" : "circle"
    }
    private func phaseColor(_ index: Int) -> Color {
        index < currentPhase || state == .completed ? LocusTheme.success
            : index == currentPhase ? stateColor : LocusTheme.lineStrong
    }
    private var stateSymbol: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .interrupted where presentation.canRecover: "pause.circle.fill"
        case .failed, .interrupted, .cancelled, .discarded: "xmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval: "clock.fill"
        default: "person.2.fill"
        }
    }
    private var stateColor: Color {
        switch state {
        case .completed: LocusTheme.success
        case .interrupted where presentation.canRecover: LocusTheme.warning
        case .failed, .interrupted, .cancelled, .discarded: LocusTheme.coral
        case .paused, .waitingPermission, .waitingComputer, .waitingDispatchApproval: LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }
    private var statusExplanation: String? {
        if state == .paused {
            return run?.recoveryReason
                ?? visibleActivities.first(where: { $0.state == .paused })?.output
                ?? "This run is saved at a safe checkpoint and can be resumed."
        }
        if state == .waitingPermission { return "A coding job is waiting for a tool permission decision below." }
        if state == .waitingComputer { return "A coding job is waiting for computer control." }
        if state == .failed || state == .interrupted {
            if isActive, let recovery = model.lifecycleRecoveryMessage { return recovery }
            return run?.recoveryReason ?? "The team run stopped before completion."
        }
        return nil
    }
    private var terminalSummary: String {
        let completed = run?.completedJobCount
            ?? (isActive ? teamRunLive.agentActivities.filter { $0.state == .completed }.count : 0)
        let total = run?.jobCount ?? (isActive ? teamRunLive.agentActivities.count : 0)
        let jobs = total > 0 ? "\(completed)/\(total) jobs" : "Run finished"
        let duration: String
        if let run {
            let end = run.completedAt ?? run.updatedAt
            let seconds = max(Int(end - run.createdAt), 0)
            duration = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        } else {
            duration = ""
        }
        let changes = isActive && landingFlow.taskHasChanges ? "changes ready" : ""
        let failure = state == .completed ? "" : (run?.recoveryReason ?? "")
        return [jobs, duration, changes, failure]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Lives in the request's conversation board while the selected team's
/// dispatcher is building a plan. It reports observable stages and validation
/// diagnostics without presenting provider reasoning or raw structured output.
struct TeamDispatchProgressView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @EnvironmentObject private var runs: OrchestrationRunsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(now: timeline.date)
        }
    }

    private func content(now: Date) -> some View {
        let startedAt = teamRunLive.dispatcherActivity?.startedAt ?? model.activeWorkStartedAt
        let elapsed = startedAt.map { max(now.timeIntervalSince($0), 0) } ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Dispatcher is creating the team plan")
                VStack(alignment: .leading, spacing: 2) {
                    Text("DISPATCHER PLANNING")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityIdentifier("teamDispatch.progress")
                    Text(teamRunLive.activeOrchestrationTeam?.name ?? "Team run")
                        .font(.locus(size: 12, weight: .bold))
                }
                Spacer()
                if startedAt != nil {
                    Text(duration(elapsed))
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(13)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.locus(size: 13, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dispatcherName)
                            .font(.locus(size: 11, weight: .semibold))
                        Text(dispatcherRoute)
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                            .lineLimit(2)
                        Text(stageDetail)
                            .font(.locus(size: 10))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(4)
                    }
                }

                if let reason = teamRunLive.dispatcherValidationReason, !reason.isEmpty {
                    Label(reason, systemImage: "arrow.triangle.2.circlepath")
                        .font(.locus(size: 9, weight: .medium))
                        .foregroundStyle(LocusTheme.warning)
                        .lineLimit(3)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.warning.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityIdentifier("teamDispatch.validationReason")
                }

                VStack(alignment: .leading, spacing: 5) {
                    stageRow(
                        "Dispatcher connected",
                        complete: teamRunLive.dispatcherActivity != nil
                    )
                    stageRow(
                        teamRunLive.dispatcherValidationReason == nil
                            ? "Create and validate one complete team plan"
                            : "Correct and revalidate the team plan",
                        complete: teamRunLive.dispatcherActivity?.state == .completed
                    )
                    stageRow("Show the plan for your approval", complete: false)
                }
                .padding(9)
                .background(LocusTheme.paperDeep.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if !requestSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REQUEST")
                            .font(.locus(size: 7, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(LocusTheme.muted)
                        Text(requestSummary)
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(3)
                    }
                }
            }
            .padding(13)

            Divider()

            HStack {
                Text("No agents or jobs begin until you approve the completed plan once.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                if let runID = model.orchestrationRunID {
                    Button("Stop", role: .destructive) {
                        model.cancelOrchestration(runID)
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
                    .accessibilityIdentifier("teamDispatch.stop")
                }
            }
            .padding(12)
        }
        .locusCard(radius: 13)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 9)
        .accessibilityElement(children: .contain)
    }

    private func stageRow(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dotted")
                .font(.locus(size: 9))
                .foregroundStyle(complete ? LocusTheme.success : LocusTheme.signalDeep)
                .frame(width: 12)
            Text(title)
                .font(.locus(size: 9, weight: complete ? .medium : .regular))
                .foregroundStyle(LocusTheme.inkSoft)
        }
    }

    private var dispatcherName: String {
        teamRunLive.dispatcherActivity?.agentName ?? dispatcherProfile?.name ?? "Starting dispatcher…"
    }

    private var dispatcherRoute: String {
        if let activity = teamRunLive.dispatcherActivity, !activity.model.isEmpty {
            return [activity.provider, activity.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard let profile = dispatcherProfile else { return "Preparing model route" }
        let provider: String
        switch profile.route {
        case .localOllama:
            provider = "Local Ollama"
        case .providerAccount(let id):
            provider = providerAccounts.providerAccounts.first(where: { $0.id == id })?.displayName
                ?? "Configured provider"
        }
        return "\(provider) · \(profile.model)"
    }

    private var stageDetail: String {
        if let output = teamRunLive.dispatcherActivity?.output, !output.isEmpty { return output }
        if teamRunLive.dispatcherActivity == nil {
            return "Opening the dispatcher route and preparing the team roster."
        }
        return "Creating assignments, dependencies, and the ordered coding sequence."
    }

    private var dispatcherProfile: AgentProfile? {
        guard let id = teamRunLive.activeOrchestrationTeam?.dispatcherID else { return nil }
        return agentTeams.agentProfiles.first(where: { $0.id == id })
    }

    private var requestSummary: String {
        if let request = runs.selectedOrchestrationRun?.request, !request.isEmpty {
            return request
        }
        return transcriptPresentation.snapshot.blocks.last(where: { $0.kind == .user })?.text ?? ""
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

/// The one and only dispatch decision for a team run. Approving this card
/// releases the complete dependency graph; individual agents and jobs do not
/// ask for additional dispatch approval.
struct TeamDispatchApprovalPromptView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    let plan: DispatchPlan

    @State private var selection = 0
    @FocusState private var panelFocused: Bool

    private static let optionCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 13)
                .padding(.top, 12)
            planSummary
                .padding(.horizontal, 13)
                .padding(.top, 9)
            options
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .locusCard(radius: 13)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 9)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, Self.optionCount - 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirm(selection)
            return .handled
        }
        .onKeyPress(.escape) {
            confirm(2)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            guard press.modifiers.isEmpty,
                  let digit = Int(press.characters),
                  (1...Self.optionCount).contains(digit)
            else { return .ignored }
            confirm(digit - 1)
            return .handled
        }
        .onTapGesture { panelFocused = true }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TEAM PLAN READY")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.signalDeep)
                .accessibilityIdentifier("teamDispatch.approval")
            HStack(spacing: 7) {
                Image(systemName: "person.2.fill")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("\(plan.jobs.count) jobs")
                    .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Approve this complete plan once?")
                    .font(.locus(size: 12, weight: .bold))
            }
            Text("After Run Plan, every listed job and any bounded read-only children proceed without another dispatch approval. Writers still cannot delegate, and tool permissions continue to follow your security settings.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.locus(size: 10, weight: .medium))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(executionOrderedJobs.enumerated()), id: \.element.id) { index, job in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.locus(size: 9, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(agentName(for: job))
                                    .font(.locus(size: 9, weight: .semibold))
                                Text("· \(jobLabel(job))")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            Text(job.goal)
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(2)
                            if !job.dependencies.isEmpty {
                                Text("After: \(job.dependencies.joined(separator: ", "))")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("teamDispatch.jobs")

            if let budget = plan.budget ?? teamRunLive.activeOrchestrationTeam?.budget {
                HStack(spacing: 8) {
                    budgetPill("\(budget.maxJobs) jobs max")
                    budgetPill(
                        budget.callBudgetMode == .automatic
                            ? "Automatic · up to 100 calls"
                            : "\(budget.maxModelCalls) calls fixed"
                    )
                    budgetPill("\(budget.maxConcurrentCalls) concurrent")
                    if let cost = plan.maximumEstimatedCost, cost > 0 {
                        budgetPill(cost.formatted(.currency(code: "USD")))
                    }
                }
            }

            let policy = plan.swarmPolicy ?? teamRunLive.activeOrchestrationTeam?.resolvedSwarmPolicy
            if let policy, policy.delegationMode == .readOnlyChildren {
                HStack(spacing: 8) {
                    budgetPill("Adaptive read-only children")
                    budgetPill("\(policy.maxTotalAgents) agents total")
                    budgetPill("Depth \(policy.maxDepth)")
                    budgetPill(policy.engine.title)
                }
                Text("This approval covers only narrower read-only children beneath the listed specialist goals and within this provider roster and cost ceiling.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("teamDispatch.swarmScope")
            }

            if let roster = plan.providerRoster, !roster.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("APPROVED PROVIDERS")
                        .font(.locus(size: 7, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(LocusTheme.muted)
                    ForEach(roster) { provider in
                        Text("\(provider.agentName) · \(provider.provider) · \(provider.model)\(provider.readOnly ? " · read only" : " · writer")")
                            .font(.locus(size: 7, design: .monospaced))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("teamDispatch.providerRoster")
            }

            Button("Review or edit in Runs") {
                model.selectInspectorTab(.runs)
            }
            .buttonStyle(.locus())
            .font(.locus(size: 8, weight: .semibold))
            .accessibilityIdentifier("teamDispatch.openRuns")
        }
        .padding(10)
        .background(LocusTheme.paperDeep.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var options: some View {
        VStack(spacing: 1) {
            optionRow(
                index: 0,
                title: "Run Plan",
                detail: "Approve once and start the complete team plan",
                identifier: "teamDispatch.run"
            )
            optionRow(
                index: 1,
                title: "Re-dispatch",
                detail: "Ask the dispatcher to replace this plan",
                identifier: "teamDispatch.redispatch"
            )
            optionRow(
                index: 2,
                title: "Cancel",
                detail: "Stop this team run before any jobs begin",
                keyCap: "esc",
                identifier: "teamDispatch.cancel"
            )
        }
    }

    private func optionRow(
        index: Int,
        title: String,
        detail: String,
        keyCap: String? = nil,
        identifier: String
    ) -> some View {
        let isSelected = index == selection
        return Button {
            confirm(index)
        } label: {
            HStack(spacing: 8) {
                Text(isSelected ? "❯" : " ")
                    .font(.locus(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(index + 1).")
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.locus(size: 11, weight: isSelected ? .semibold : .regular))
                    Text(detail)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                .lineLimit(1)
                Spacer()
                if let keyCap {
                    Text(keyCap)
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                }
                if isSelected {
                    Text("↵")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(isSelected ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .onHover { hovering in
            if hovering { selection = index }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func budgetPill(_ text: String) -> some View {
        Text(text)
            .font(.locus(size: 7, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(LocusTheme.white.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func agentName(for job: DispatchJob) -> String {
        guard let id = UUID(uuidString: job.agentID) else { return job.agentID }
        return agentTeams.agentProfiles.first(where: { $0.id == id })?.name ?? job.agentID
    }

    private func jobLabel(_ job: DispatchJob) -> String {
        guard job.kind == "writer" else { return job.kind.capitalized }
        let writers = executionOrderedJobs.filter { $0.kind == "writer" }
        guard let index = writers.firstIndex(where: { $0.id == job.id }) else { return "Coding" }
        return "Coding \(index + 1) of \(writers.count)"
    }

    /// Mirrors the backend's execution phases so the approval card exposes
    /// the actual serialized coding order even when the dispatcher returned
    /// jobs in a different JSON array order.
    private var executionOrderedJobs: [DispatchJob] {
        let specialists = topologicalJobs(
            plan.jobs.filter { $0.kind == "specialist" },
            completed: []
        )
        let specialistIDs = Set(specialists.map(\.id))
        let writers = topologicalJobs(
            plan.jobs.filter { $0.kind == "writer" },
            completed: specialistIDs
        )
        let reviewers = plan.jobs.filter { $0.kind == "reviewer" }
        let ordered = specialists + writers + reviewers
        return ordered.count == plan.jobs.count ? ordered : plan.jobs
    }

    private func topologicalJobs(
        _ jobs: [DispatchJob],
        completed initial: Set<String>
    ) -> [DispatchJob] {
        var completed = initial
        var pending = jobs
        var ordered: [DispatchJob] = []
        while !pending.isEmpty {
            let ready = pending.filter { Set($0.dependencies).isSubset(of: completed) }
            guard !ready.isEmpty else { return jobs }
            let readyIDs = Set(ready.map(\.id))
            ordered.append(contentsOf: ready)
            completed.formUnion(readyIDs)
            pending.removeAll { readyIDs.contains($0.id) }
        }
        return ordered
    }

    private func confirm(_ index: Int) {
        switch index {
        case 0: model.decideDispatch("run")
        case 1: model.decideDispatch("redispatch")
        default: model.decideDispatch("cancel")
        }
    }
}

/// The composer-area follow-up to a finished Plan-mode run, the way Claude
/// Code closes plan mode: the input is replaced by this panel until the user
/// decides whether the plan gets implemented. ↑/↓ move the selection, 1–3
/// answer directly, ↵ confirms, esc cancels.
struct PlanApprovalPromptView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection = 0
    @FocusState private var panelFocused: Bool

    private static let optionCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 13)
                .padding(.top, 12)
            steps
                .padding(.horizontal, 13)
                .padding(.top, 9)
            options
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .locusCard(radius: 13)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 22, y: 9)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, Self.optionCount - 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirm(selection)
            return .handled
        }
        .onKeyPress(.escape) {
            confirm(2)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            guard press.modifiers.isEmpty,
                  let digit = Int(press.characters),
                  (1...Self.optionCount).contains(digit)
            else { return .ignored }
            confirm(digit - 1)
            return .handled
        }
        .onTapGesture { panelFocused = true }
        .onAppear { panelFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan approval")
        .accessibilityIdentifier("planApproval.panel")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PLAN READY")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.signalDeep)
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .accessibilityHidden(true)
                Text("\(planSteps.count) steps")
                    .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Do you want to implement this plan?")
                    .font(.locus(size: 12, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(planSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1).")
                        .font(.locus(size: 10, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                    Text(step)
                        .font(.locus(size: 10, weight: .medium))
                        .foregroundStyle(LocusTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(LocusTheme.paperDeep.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityIdentifier("planApproval.steps")
    }

    private var options: some View {
        VStack(spacing: 1) {
            optionRow(
                index: 0,
                title: "Proceed",
                detail: "Switch to Work and implement with current permissions",
                identifier: "planApproval.proceed"
            )
            optionRow(
                index: 1,
                title: "Revise",
                detail: "Stay in Plan and refine this plan",
                identifier: "planApproval.revise"
            )
            optionRow(
                index: 2,
                title: "Cancel",
                detail: "Return to adaptive Work and keep the plan for reference",
                keyCap: "esc",
                identifier: "planApproval.cancel"
            )
        }
    }

    private func optionRow(
        index: Int,
        title: String,
        detail: String,
        keyCap: String? = nil,
        identifier: String
    ) -> some View {
        let isSelected = index == selection
        return Button {
            confirm(index)
        } label: {
            HStack(spacing: 8) {
                Text(isSelected ? "❯" : " ")
                    .font(.locus(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(index + 1).")
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.locus(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(LocusTheme.ink)
                    Text(detail)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                .lineLimit(1)
                Spacer()
                if let keyCap {
                    Text(keyCap)
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                }
                if isSelected {
                    Text("↵")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(isSelected ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .onHover { hovering in
            if hovering { selection = index }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func confirm(_ index: Int) {
        let decision: PlanApprovalDecision = index == 0
            ? .proceed
            : index == 1 ? .revise : .cancel
        model.resolvePlanApproval(decision)
    }

    private var planSteps: [String] {
        model.activePlan?.steps ?? model.todos.map(\.content)
    }
}
