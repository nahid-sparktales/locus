import SwiftUI

/// The composer-replacing prompt for a question the agent asked. Same
/// contract as `PlanApprovalPromptView`: the question is a decision point, so
/// the decision replaces the input. Options are keyboard-driven; a free-text
/// row is always present, and `esc` hands the answer back to the composer.
struct QuestionPromptView: View {
    @EnvironmentObject private var model: AppModel

    let question: UserQuestion
    var onResolve: ((UserQuestionOption?, String) -> Void)? = nil
    var onDismiss: ((String) -> Void)? = nil

    @State private var selection = 0
    @State private var answerText = ""
    @FocusState private var panelFocused: Bool
    @FocusState private var textFocused: Bool

    private enum Row: Hashable {
        /// Index into `question.options`.
        case option(Int)
        /// A freeform recommendation with no option list to live in.
        case recommendation
        case freeText
    }

    private var rows: [Row] {
        var rows: [Row] = question.options.indices.map(Row.option)
        if question.options.isEmpty, !question.recommended.isEmpty {
            rows.append(.recommendation)
        }
        rows.append(.freeText)
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 13)
                .padding(.top, 12)
            if !question.question.isEmpty {
                bodyCard
                    .padding(.horizontal, 13)
                    .padding(.top, 9)
            }
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
            guard !textFocused else { return .ignored }
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !textFocused else { return .ignored }
            selection = min(selection + 1, rows.count - 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !textFocused else { return .ignored }
            confirm(rows[min(selection, rows.count - 1)])
            return .handled
        }
        .onKeyPress(.escape) {
            if let onDismiss { onDismiss(answerText) }
            else { model.dismissUserQuestion(keepingDraft: answerText) }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard !textFocused,
                  press.modifiers.isEmpty,
                  let digit = Int(press.characters),
                  (1...rows.count).contains(digit)
            else { return .ignored }
            confirm(rows[digit - 1])
            return .handled
        }
        .onTapGesture { panelFocused = true }
        .onAppear {
            panelFocused = true
            selection = defaultSelection
        }
        .onChange(of: textFocused) { _, focused in
            if focused, let index = rows.firstIndex(of: .freeText) {
                selection = index
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent")
        .accessibilityIdentifier("questionPrompt.panel")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("QUESTION")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.signalDeep)
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .accessibilityHidden(true)
                Text(question.title)
                    .font(.locus(size: 12, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
            }
        }
    }

    private var bodyCard: some View {
        Text(question.question)
            .font(.locus(size: 10, weight: .medium))
            .foregroundStyle(LocusTheme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(LocusTheme.paperDeep.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityIdentifier("questionPrompt.body")
    }

    private var options: some View {
        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                switch row {
                case .option(let optionIndex):
                    optionRow(
                        index: index,
                        title: question.options[optionIndex].label,
                        detail: question.options[optionIndex].detail,
                        recommended: question.recommendedOptionIndex == optionIndex,
                        identifier: "questionPrompt.option.\(optionIndex)"
                    )
                case .recommendation:
                    optionRow(
                        index: index,
                        title: question.recommended,
                        detail: "The agent's recommended answer",
                        recommended: true,
                        identifier: "questionPrompt.recommendation"
                    )
                case .freeText:
                    freeTextRow(index: index)
                }
            }
            // `muted` measures under the audit's 4.5:1 floor at 1x on the
            // bare panel; standalone hint text takes the secondary role, the
            // way the Runs panel's small text does.
            Text("esc dismisses and answers in the composer")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 5)
        }
    }

    private func optionRow(
        index: Int,
        title: String,
        detail: String,
        recommended: Bool,
        identifier: String
    ) -> some View {
        let isSelected = index == selection
        return Button {
            confirm(rows[index])
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
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                .lineLimit(1)
                Spacer()
                if recommended {
                    Text("Recommended")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(LocusTheme.paperDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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

    private func freeTextRow(index: Int) -> some View {
        let isSelected = index == selection
        // Unlike the option rows, this row is not a Button, so its decorative
        // glyphs would surface as bare StaticTexts — the blank caret
        // placeholder reads as zero-contrast "text" to the audit. The
        // TextField carries the row's semantics.
        return HStack(spacing: 8) {
            Text(isSelected ? "❯" : " ")
                .font(.locus(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.signalDeep)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text("\(index + 1).")
                .font(.locus(size: 10, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .accessibilityHidden(true)
            TextField("Type your own answer…", text: $answerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1...4)
                .focused($textFocused)
                .onSubmit { confirm(.freeText) }
                .accessibilityIdentifier("questionPrompt.freeText")
            if !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    confirm(.freeText)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.locus(size: 13, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                }
                .buttonStyle(.locus())
                .help("Send answer")
                .accessibilityIdentifier("questionPrompt.submit")
            } else if isSelected {
                Text("↵")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 38)
        .background(isSelected ? LocusTheme.paperDeep : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { textFocused = true }
        .onHover { hovering in
            if hovering { selection = index }
        }
    }

    // MARK: - Behavior

    private var defaultSelection: Int {
        if let recommended = question.recommendedOptionIndex,
           let index = rows.firstIndex(of: .option(recommended))
        {
            return index
        }
        if let index = rows.firstIndex(of: .recommendation) { return index }
        return rows.firstIndex(of: .freeText) ?? 0
    }

    private func confirm(_ row: Row) {
        switch row {
        case .option(let optionIndex):
            resolve(option: question.options[optionIndex], text: answerText)
        case .recommendation:
            resolve(option: UserQuestionOption(label: question.recommended), text: answerText)
        case .freeText:
            let typed = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else {
                textFocused = true
                return
            }
            resolve(option: nil, text: typed)
        }
    }

    private func resolve(option: UserQuestionOption?, text: String) {
        if let onResolve { onResolve(option, text) }
        else { model.resolveUserQuestion(option: option, freeText: text) }
    }
}
