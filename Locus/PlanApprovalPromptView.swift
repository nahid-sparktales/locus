import SwiftUI

/// The composer-area follow-up to a finished Plan-mode run, the way Claude
/// Code closes plan mode: the input is replaced by this panel until the user
/// decides whether the plan gets implemented. ↑/↓ move the selection, 1–3
/// answer directly, ↵ confirms, esc keeps planning.
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
                Text("\(model.todos.count) steps")
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
                ForEach(Array(model.todos.enumerated()), id: \.element.id) { index, todo in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                        Text(todo.content)
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
                title: "Yes, and auto-accept edits",
                identifier: "planApproval.autoAccept"
            )
            optionRow(
                index: 1,
                title: "Yes, and approve each edit as it happens",
                identifier: "planApproval.review"
            )
            optionRow(
                index: 2,
                title: "No, keep planning",
                keyCap: "esc",
                identifier: "planApproval.keep"
            )
        }
    }

    private func optionRow(
        index: Int,
        title: String,
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
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(LocusTheme.ink)
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
            .frame(height: 30)
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
            ? .implementAutoAccepting
            : index == 1 ? .implementReviewing : .keepPlanning
        model.resolvePlanApproval(decision)
    }
}
