import SwiftUI

/// Replaces the composer while the selected team's dispatcher is building a
/// plan. It reports observable stages and validation diagnostics without
/// presenting provider reasoning or raw structured output.
struct TeamDispatchProgressView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(now: timeline.date)
        }
    }

    private func content(now: Date) -> some View {
        let startedAt = model.dispatcherActivity?.startedAt ?? model.activeWorkStartedAt
        let elapsed = startedAt.map { max(now.timeIntervalSince($0), 0) } ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Dispatcher is creating the team plan")
                VStack(alignment: .leading, spacing: 2) {
                    Text("DISPATCHER PLANNING")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text(model.activeOrchestrationTeam?.name ?? "Team run")
                        .font(.system(size: 12, weight: .bold))
                }
                Spacer()
                if startedAt != nil {
                    Text(duration(elapsed))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(13)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dispatcherName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(dispatcherRoute)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                            .lineLimit(2)
                        Text(stageDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(4)
                    }
                }

                if let reason = model.dispatcherValidationReason, !reason.isEmpty {
                    Label(reason, systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .medium))
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
                        complete: model.dispatcherActivity != nil
                    )
                    stageRow(
                        model.dispatcherValidationReason == nil
                            ? "Create and validate one complete team plan"
                            : "Correct and revalidate the team plan",
                        complete: model.dispatcherActivity?.state == .completed
                    )
                    stageRow("Show the plan for your approval", complete: false)
                }
                .padding(9)
                .background(LocusTheme.paperDeep.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if !requestSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REQUEST")
                            .font(.system(size: 7, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(LocusTheme.muted)
                        Text(requestSummary)
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(3)
                    }
                }
            }
            .padding(13)

            Divider()

            HStack {
                Text("No agents or jobs begin until you approve the completed plan once.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                if let runID = model.orchestrationRunID {
                    Button("Stop", role: .destructive) {
                        model.cancelOrchestration(runID)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9, weight: .semibold))
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
        .accessibilityIdentifier("teamDispatch.progress")
    }

    private func stageRow(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 9))
                .foregroundStyle(complete ? LocusTheme.success : LocusTheme.signalDeep)
                .frame(width: 12)
            Text(title)
                .font(.system(size: 9, weight: complete ? .medium : .regular))
                .foregroundStyle(LocusTheme.inkSoft)
        }
    }

    private var dispatcherName: String {
        model.dispatcherActivity?.agentName ?? dispatcherProfile?.name ?? "Starting dispatcher…"
    }

    private var dispatcherRoute: String {
        if let activity = model.dispatcherActivity, !activity.model.isEmpty {
            return [activity.provider, activity.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard let profile = dispatcherProfile else { return "Preparing model route" }
        let provider: String
        switch profile.route {
        case .localOllama:
            provider = "Local Ollama"
        case .providerAccount(let id):
            provider = model.providerAccounts.first(where: { $0.id == id })?.displayName
                ?? "Configured provider"
        }
        return "\(provider) · \(profile.model)"
    }

    private var stageDetail: String {
        if let output = model.dispatcherActivity?.output, !output.isEmpty { return output }
        if model.dispatcherActivity == nil {
            return "Opening the dispatcher route and preparing the team roster."
        }
        return "Creating assignments, dependencies, and the single-writer boundary."
    }

    private var dispatcherProfile: AgentProfile? {
        guard let id = model.activeOrchestrationTeam?.dispatcherID else { return nil }
        return model.agentProfiles.first(where: { $0.id == id })
    }

    private var requestSummary: String {
        if let request = model.selectedOrchestrationRun?.request, !request.isEmpty {
            return request
        }
        return model.blocks.last(where: { $0.kind == .user })?.text ?? ""
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
        .onAppear { panelFocused = true }
        .accessibilityIdentifier("teamDispatch.approval")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TEAM PLAN READY")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.signalDeep)
            HStack(spacing: 7) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("\(plan.jobs.count) jobs")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Approve this complete plan once?")
                    .font(.system(size: 12, weight: .bold))
            }
            Text("After Run Plan, every listed agent and step proceeds without another dispatch approval. Tool permissions still follow your security settings.")
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(plan.jobs.enumerated()), id: \.element.id) { index, job in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(agentName(for: job))
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("· \(job.kind.capitalized)")
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Text(job.goal)
                                    .font(.system(size: 9))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .lineLimit(2)
                                if !job.dependencies.isEmpty {
                                    Text("After: \(job.dependencies.joined(separator: ", "))")
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .accessibilityIdentifier("teamDispatch.jobs")

            if let budget = plan.budget ?? model.activeOrchestrationTeam?.budget {
                HStack(spacing: 8) {
                    budgetPill("\(budget.maxJobs) jobs max")
                    budgetPill("\(budget.maxModelCalls) calls")
                    budgetPill("\(budget.maxConcurrentCalls) concurrent")
                    if let cost = plan.maximumEstimatedCost, cost > 0 {
                        budgetPill(cost.formatted(.currency(code: "USD")))
                    }
                }
            }

            Button("Review or edit in Runs") {
                model.selectInspectorTab(.runs)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 8, weight: .semibold))
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(index + 1).")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                .lineLimit(1)
                Spacer()
                if let keyCap {
                    Text(keyCap)
                        .font(.system(size: 8, design: .monospaced))
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
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(isSelected ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selection = index }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func budgetPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(LocusTheme.white.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func agentName(for job: DispatchJob) -> String {
        guard let id = UUID(uuidString: job.agentID) else { return job.agentID }
        return model.agentProfiles.first(where: { $0.id == id })?.name ?? job.agentID
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
        .accessibilityIdentifier("planApproval.panel")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PLAN READY")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.signalDeep)
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("\(planSteps.count) steps")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Do you want to implement this plan?")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(planSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                        Text(step)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LocusTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 132)
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
                detail: "Switch to Build and implement with current permissions",
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(index + 1).")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(LocusTheme.ink)
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                .lineLimit(1)
                Spacer()
                if let keyCap {
                    Text(keyCap)
                        .font(.system(size: 8, design: .monospaced))
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
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(isSelected ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
