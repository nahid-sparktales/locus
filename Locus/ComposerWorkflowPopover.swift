import SwiftUI

/// Modes affect the next message. Goals and capsules open their own setup;
/// keeping those actions in a separate section avoids implying a mode change.
struct ComposerWorkflowPopover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    let selectMode: (WorkMode) -> Void
    let openGoal: () -> Void
    let openCapsules: () -> Void
    let openTeams: () -> Void
    let dismiss: () -> Void
    @FocusState private var panelFocused: Bool
    @State private var keyboardChoice: Choice = .mode(.work)
    @State private var usesKeyboard = false

    private enum Choice: Equatable {
        case mode(WorkMode), goal, capsules, teams
    }

    private var availableChoices: [Choice] {
        var choices: [Choice] = [.mode(.work), .mode(.plan), .mode(.grill)]
        if !model.isIdentityTask { choices.insert(.mode(.duo), at: 2) }
        if model.canStartGoal { choices.append(.goal) }
        if !model.isIdentityTask { choices.append(.capsules) }
        choices.append(.teams)
        return choices
    }

    static func symbol(for mode: WorkMode) -> String {
        switch mode {
        case .ask: "bubble.left"
        case .work: "sparkles"
        case .plan: "list.bullet.clipboard"
        case .duo: "person.2"
        case .grill: "questionmark.bubble"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How Locus works")
                .font(.locus(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 6)

            ForEach([WorkMode.work, .plan] + (model.isIdentityTask ? [] : [.duo]) + [.grill]) { mode in
                row(
                    mode.title,
                    choice: .mode(mode),
                    detail: detail(for: mode),
                    symbol: Self.symbol(for: mode),
                    selected: model.selectedMode == mode
                ) { selectMode(mode) }
                .accessibilityLabel("\(mode.title) mode")
                .accessibilityValue(model.selectedMode == mode ? "Selected" : "Not selected")
                .accessibilityAddTraits(model.selectedMode == mode ? .isSelected : [])
                .accessibilityIdentifier("composer.mode.\(mode.rawValue)")
            }

            Divider().padding(.vertical, 5)
            Text("Longer tasks")
                .font(.locus(size: 9, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            if model.backendCapabilities["persistent_goals_v1"] == true {
                row("Goal…", choice: .goal, detail: goalDetail, symbol: "scope", action: openGoal)
                    .disabled(!model.canStartGoal)
                    .accessibilityIdentifier("composer.goal")
            }
            row(
                "Task Capsules…",
                choice: .capsules,
                detail: model.isIdentityTask
                    ? "Open a regular task to use saved plans."
                    : "Save a plan. Choose models. Run it when ready.",
                symbol: "square.stack.3d.up",
                action: openCapsules
            )
            .disabled(model.isIdentityTask)
            .accessibilityIdentifier("composer.capsules")

            Divider().padding(.vertical, 5)
            row(
                "Solo or team…",
                choice: .teams,
                detail: agentTeams.selectedAgentTeam?.name ?? "Solo · use the current conversation model",
                symbol: agentTeams.teamModeEnabled ? "person.2" : "person",
                action: openTeams
            )
            .accessibilityLabel("Solo or team routing")
            .accessibilityValue(agentTeams.selectedAgentTeam?.name ?? "Solo")
            .accessibilityIdentifier("composer.team")
        }
        .padding(8)
        .frame(width: 320)
        .background(LocusTheme.panel)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onAppear {
            keyboardChoice = .mode(model.selectedMode)
            panelFocused = true
        }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.tab, phases: .down) { press in
            moveSelection(press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        .onKeyPress(.return) { activateSelection(); return .handled }
        .onKeyPress(.space) { activateSelection(); return .handled }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func moveSelection(_ offset: Int) {
        let choices = availableChoices
        let index = choices.firstIndex(of: keyboardChoice) ?? 0
        keyboardChoice = choices[(index + offset + choices.count) % choices.count]
        usesKeyboard = true
    }

    private func activateSelection() {
        guard availableChoices.contains(keyboardChoice) else { return }
        switch keyboardChoice {
        case .mode(let mode): selectMode(mode)
        case .goal: openGoal()
        case .capsules: openCapsules()
        case .teams: openTeams()
        }
    }

    private var goalDetail: String {
        if model.canStartGoal { return "Keep working toward an objective across turns." }
        if model.isIdentityTask { return "Open a regular task to set a goal." }
        return "Available when this conversation is ready for a goal."
    }

    private func detail(for mode: WorkMode) -> String {
        switch mode {
        case .work: "Let Locus choose the approach and get it done."
        case .plan: "Review a plan before making changes."
        case .duo: "Plan with one model. Accept, then build with another."
        case .grill: "Sharpen your idea with one question at a time."
        case .ask: mode.description
        }
    }

    private func row(
        _ title: String,
        choice: Choice,
        detail: String,
        symbol: String,
        selected: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        ComposerWorkflowRow(
            title: title, detail: detail, symbol: symbol,
            selected: selected, highlighted: usesKeyboard && keyboardChoice == choice,
            accent: model.accentActionColor, action: action
        )
        .onHover { hovering in
            if hovering { usesKeyboard = false; keyboardChoice = choice }
        }
    }
}

private struct ComposerWorkflowRow: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool?
    let highlighted: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.locus(size: 13, weight: .medium))
                    .foregroundStyle(selected == true ? accent : LocusTheme.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.locus(size: 11, weight: .medium))
                        .foregroundStyle(LocusTheme.ink)
                    Text(detail)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected == nil ? "chevron.right" : "checkmark")
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(selected == true ? accent : LocusTheme.muted)
                    .opacity(selected == false ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected == true ? accent.opacity(0.08) : (hovering && isEnabled ? LocusTheme.paperDeep : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(highlighted ? accent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.locus())
        .onHover { hovering = $0 }
        .help(detail)
    }
}
