import SwiftUI

/// The composer-area question panel, the way Claude Code and Codex ask: while
/// the agent is blocked on an answer the input is replaced by this card, so the
/// decision is where your hands already are. ↑/↓ move the selection, 1–4 pick,
/// `o` jumps to the free-text field, ↵ confirms, esc dismisses.
///
/// A question with no options is not a special case — it renders the same card
/// with the entry field focused on appear.
struct BlockingQuestionPromptView: View {
    @EnvironmentObject private var model: AppModel
    let request: AgentQuestionRequest

    /// Two focus targets, not one: a `TextField` swallows 1–4, ↑/↓ and ↵, so
    /// the panel keeps its own focus while the entry field is idle.
    private enum Field: Hashable { case panel, entry }

    @FocusState private var focus: Field?
    @State private var index = 0
    @State private var selection = 0
    @State private var chosen: Set<String> = []
    @State private var entry = ""
    @State private var answers: [AgentQuestionAnswer] = []

    private var current: AgentQuestion {
        request.questions.indices.contains(index)
            ? request.questions[index]
            : AgentQuestion()
    }

    /// The options plus the always-present "type your own answer" row.
    private var rowCount: Int { current.options.count + 1 }
    private var isOtherRow: Bool { selection == current.options.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 13)
                .padding(.top, 12)
            questionBody
                .padding(.horizontal, 13)
                .padding(.top, 9)
            rows
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
        .focused($focus, equals: .panel)
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, rowCount - 1)
            return .handled
        }
        .onKeyPress(.return) {
            if isOtherRow { focus = .entry } else { advance() }
            return .handled
        }
        .onKeyPress(.escape) {
            skip()
            return .handled
        }
        .onKeyPress(.space) {
            guard current.multiSelect, !isOtherRow else { return .ignored }
            toggle(current.options[selection].label)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard press.modifiers.isEmpty,
                  let digit = Int(press.characters),
                  (1...current.options.count).contains(digit)
            else { return .ignored }
            let label = current.options[digit - 1].label
            if current.multiSelect {
                selection = digit - 1
                toggle(label)
            } else {
                selection = digit - 1
                advance()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "o")) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            selection = current.options.count
            focus = .entry
            return .handled
        }
        .onTapGesture { focus = .panel }
        .onAppear { resetForCurrentQuestion() }
        .onChange(of: request.id) { resetAll() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question")
        .accessibilityIdentifier("question.panel")
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
                if !current.header.isEmpty {
                    Text(current.header)
                        .font(.locus(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(LocusTheme.paperDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(current.multiSelect ? "Choose any that apply" : "Choose one, or type your own")
                    .font(.locus(size: 12, weight: .bold))
                    .foregroundStyle(LocusTheme.ink)
                Spacer()
                if request.questions.count > 1 {
                    Text("\(index + 1) / \(request.questions.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("question.progress")
                }
            }
        }
    }

    private var questionBody: some View {
        Text(current.question)
            .font(.locus(size: 11, weight: .medium))
            .foregroundStyle(LocusTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(LocusTheme.paperDeep.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityIdentifier("question.body")
    }

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { offset, option in
                optionRow(offset: offset, option: option)
            }
            otherRow
            if focus == .entry || current.options.isEmpty {
                entryField
            }
        }
    }

    private func optionRow(offset: Int, option: AgentQuestionOption) -> some View {
        let isSelected = offset == selection
        let isChosen = chosen.contains(option.label)
        return Button {
            selection = offset
            if current.multiSelect { toggle(option.label) } else { advance() }
        } label: {
            HStack(spacing: 8) {
                Text(current.multiSelect ? (isChosen ? "✓" : " ") : (isSelected ? "❯" : " "))
                    .font(.locus(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text("\(offset + 1).")
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.locus(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(LocusTheme.ink)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                .lineLimit(1)
                Spacer()
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
        .onHover { hovering in if hovering { selection = offset } }
        .accessibilityLabel(option.label)
        .accessibilityValue(current.multiSelect && isChosen ? "Selected" : "")
        .accessibilityIdentifier("question.option.\(offset + 1)")
    }

    /// Always present, even when there are options: the user must never be
    /// boxed into the model's guesses.
    private var otherRow: some View {
        let isSelected = isOtherRow
        return Button {
            selection = current.options.count
            focus = .entry
        } label: {
            HStack(spacing: 8) {
                Text(isSelected ? "❯" : " ")
                    .font(.locus(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 10)
                Text(current.options.isEmpty ? " " : "o.")
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                Text(current.options.isEmpty ? "Type your answer" : "Something else…")
                    .font(.locus(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(LocusTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(isSelected ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .onHover { hovering in if hovering { selection = current.options.count } }
        .accessibilityLabel("Type your own answer")
        .accessibilityIdentifier("question.other")
    }

    private var entryField: some View {
        HStack(spacing: 8) {
            TextField("Type your answer", text: $entry, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .lineLimit(1...4)
                .focused($focus, equals: .entry)
                .onSubmit { advance() }
                .onKeyPress(.escape) {
                    // esc backs out to the panel when there are options to back
                    // out to; otherwise it dismisses, as it does on the panel.
                    if current.options.isEmpty { skip() } else { focus = .panel }
                    return .handled
                }
                .accessibilityIdentifier("question.entry")
            Button("Send") { advance() }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && chosen.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(LocusTheme.paperDeep.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Behaviour

    private func toggle(_ label: String) {
        if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
    }

    private func collectedAnswer() -> AgentQuestionAnswer {
        let selected: [String]
        if current.multiSelect {
            selected = current.options.map(\.label).filter(chosen.contains)
        } else if !isOtherRow, current.options.indices.contains(selection) {
            selected = [current.options[selection].label]
        } else {
            selected = []
        }
        return AgentQuestionAnswer(
            id: current.id,
            selected: selected,
            text: entry.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func advance() {
        answers.append(collectedAnswer())
        if index + 1 < request.questions.count {
            index += 1
            resetForCurrentQuestion()
        } else {
            model.resolveBlockingQuestion(answers)
        }
    }

    /// Sends whatever has been collected so far, so a partial run still reaches
    /// the model rather than being thrown away.
    private func skip() {
        model.resolveBlockingQuestion(answers, action: "cancel")
    }

    private func resetForCurrentQuestion() {
        selection = 0
        chosen = []
        entry = ""
        focus = current.options.isEmpty ? .entry : .panel
    }

    private func resetAll() {
        index = 0
        answers = []
        resetForCurrentQuestion()
    }
}
