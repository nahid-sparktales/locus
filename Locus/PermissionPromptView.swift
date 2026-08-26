import SwiftUI

/// The composer-area permission prompt, the way Claude Code and Codex ask:
/// while a request is pending the input is replaced by this panel, so the
/// decision is always where your hands already are. ↑/↓ move the selection,
/// 1–3 answer directly, ↵ confirms, esc denies.
struct PermissionPromptView: View {
    @EnvironmentObject private var model: AppModel
    let request: ToolPayload

    @State private var selection = 0
    @FocusState private var panelFocused: Bool

    private static let optionCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 13)
                .padding(.top, 12)
            preview
                .padding(.horizontal, 13)
                .padding(.top, 9)
            options
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .locusCard(radius: 13)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LocusTheme.warning.opacity(0.55), lineWidth: 1)
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
        .onChange(of: request.requestID) {
            // The next queued request swaps into the same panel.
            selection = 0
            panelFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission.panel")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PERMISSION REQUIRED")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.warning)
            HStack(spacing: 7) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
                    .accessibilityHidden(true)
                Text(request.tool)
                    .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(question)
                    .font(.locus(size: 12, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let detail = request.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = request.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            if !summary.isEmpty, summary != detail {
                Text(summary)
                    .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if !detail.isEmpty {
                ScrollView {
                    ToolOutputText(text: detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("permission.preview.detail")
                }
                .frame(maxHeight: 132)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.paperDeep.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityIdentifier("permission.preview")
    }

    private var options: some View {
        VStack(spacing: 1) {
            optionRow(
                index: 0,
                title: "Yes, allow once",
                identifier: "permission.once"
            )
            optionRow(
                index: 1,
                title: "Yes, and don't ask again for \(toolLabel) this session",
                identifier: "permission.always"
            )
            optionRow(
                index: 2,
                title: "No, and tell Locus what to do differently",
                keyCap: "esc",
                identifier: "permission.deny"
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
                    .font(.locus(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(index + 1).")
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                Text(title)
                    .font(.locus(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(LocusTheme.ink)
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
            .frame(height: 30)
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

    // MARK: - Wording

    private var question: String {
        let lower = request.tool.lowercased()
        if lower.contains("bash") || lower.contains("shell") || lower.contains("command") {
            return "Do you want to run this command?"
        }
        if ["write", "edit", "patch", "create", "delete"].contains(where: lower.contains) {
            return "Do you want to make this change?"
        }
        return "Do you want to allow \(request.tool)?"
    }

    /// Truthful to the backend's semantics: "always" allows this tool for
    /// the rest of the session, and is cleared by "Reset session allowances".
    private var toolLabel: String {
        switch request.tool.lowercased() {
        case "bash": "bash commands"
        case "shell": "shell commands"
        default: request.tool
        }
    }

    private func confirm(_ index: Int) {
        guard let requestID = request.requestID else { return }
        let decision = index == 0 ? "once" : index == 1 ? "always" : "deny"
        model.decide(requestID: requestID, decision: decision)
    }
}
