import SwiftUI

struct GoalCardView: View {
    @ObservedObject var model: GoalModel
    let sessionID: String

    var body: some View {
        if let goal = model.goal(for: sessionID) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: goal.status == .completed ? "checkmark.circle" : "scope")
                        .foregroundStyle(LocusTheme.accentAction)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.status.title).font(.callout.weight(.semibold))
                            .accessibilityIdentifier("goal.status")
                        Text(goal.objective).font(.callout).lineLimit(3).textSelection(.enabled)
                            .accessibilityIdentifier("goal.objective")
                    }
                    Spacer(minLength: 4)
                }
                if let detail = goal.reason?.nilIfEmpty ?? goal.summary, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(4).textSelection(.enabled)
                }
                if let next = goal.nextStep, !next.isEmpty, !goal.status.isTerminal {
                    Text("Next: \(next)").font(.caption).foregroundStyle(LocusTheme.textSecondary).lineLimit(2)
                }
                if goal.status == .completed, !goal.evidence.isEmpty {
                    DisclosureGroup("Verification evidence") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(goal.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text(evidence).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
                    .accessibilityIdentifier("goal.evidence")
                }
                HStack(spacing: 12) {
                    Text(usage(goal)).font(.caption).foregroundStyle(LocusTheme.textTertiary)
                        .accessibilityIdentifier("goal.usage")
                    Spacer(minLength: 2)
                    if goal.status == .active {
                        Button("Pause") { model.pauseAndStop(sessionID: sessionID) }
                            .help("Pause this goal and stop its current work")
                            .accessibilityIdentifier("goal.pause")
                    } else if goal.status.canResume {
                        Button("Resume") { Task { await model.resume(sessionID: sessionID) } }
                            .help("Continue this goal in its chat")
                            .accessibilityIdentifier("goal.resume")
                    }
                    if !goal.status.isTerminal {
                        Button("Edit") { model.open(sessionID: sessionID) }
                            .accessibilityIdentifier("goal.edit")
                        Button("End") { Task { await model.cancel(sessionID: sessionID) } }
                            .help("Stop current work and end this goal")
                            .accessibilityLabel("End this goal")
                            .accessibilityIdentifier("goal.end")
                    }
                }
                .buttonStyle(.locus())
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(LocusTheme.danger).lineLimit(3)
                }
            }
            .padding(12)
            .background(LocusTheme.surfaceStructural.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("goal.card")
        }
    }

    private func usage(_ goal: PersistentGoal) -> String {
        let calls = goal.modelCallUsageAvailable
            ? goal.modelCallBudget.map { "\(goal.modelCalls)/\($0) calls" } ?? "\(goal.modelCalls) calls"
            : "Call usage unavailable"
        let tokens = goal.tokenUsageAvailable
            ? goal.tokenBudget.map { "\(goal.totalTokens.formatted())/\($0.formatted()) tokens" } ?? "\(goal.totalTokens.formatted()) tokens"
            : "Token usage unavailable"
        return "\(calls) · \(tokens)"
    }
}

struct GoalEditorView: View {
    @ObservedObject var model: GoalModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(model.isEditing ? "Edit goal" : "Persistent goal", systemImage: "scope")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { model.isPresented = false; dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("goal.editor.cancel")
            }
            Text("Locus keeps working in this chat until the goal is complete, needs your help, or reaches an allowance. You can pause it at any time.")
                .font(.callout).foregroundStyle(LocusTheme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("What should this task accomplish?").font(.callout.weight(.medium))
                TextEditor(text: $model.draftObjective)
                    .font(.body).scrollContentBackground(.hidden).padding(8)
                    .frame(height: 115).locusCard(radius: 8)
                    .disabled(model.isSaving)
                    .accessibilityLabel("Goal objective")
                    .accessibilityIdentifier("goal.editor.objective")
            }
            if !model.draftRouteLabel.isEmpty {
                Label(model.draftRouteLabel, systemImage: "cpu")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            }
            HStack(alignment: .top, spacing: 16) {
                budgetField("Model calls", placeholder: "No goal limit", value: $model.draftModelCallBudget, id: "goal.editor.calls")
                budgetField("Tokens", placeholder: "No goal limit", value: $model.draftTokenBudget, id: "goal.editor.tokens")
            }
            Text("Allowances count usage across all turns of this goal. Provider limits still apply. Leave an allowance empty for no goal-specific limit.")
                .font(.caption).foregroundStyle(LocusTheme.textTertiary)
            if model.isEditing {
                Text("Saving changes pauses the goal and stops its current work. Resume when you are ready to continue.")
                    .font(.caption).foregroundStyle(LocusTheme.textSecondary)
            }
            if let error = model.error ?? visibleValidationError {
                Text(error).font(.callout).foregroundStyle(LocusTheme.danger)
                    .accessibilityIdentifier("goal.editor.error")
            }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.isEditing ? "Save changes" : "Start goal") { Task { await model.saveDraft() } }
                    .buttonStyle(.locus(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                    .help(model.draftValidationError ?? (model.isEditing ? "Save the goal in a paused state" : "Start working toward this goal in the current chat"))
                    .accessibilityIdentifier("goal.editor.save")
            }
        }
        .padding(24).frame(width: 550)
        .background(LocusTheme.surfaceCanvas)
        .foregroundStyle(LocusTheme.textPrimary)
        .buttonStyle(.locus())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal.editor")
    }

    private var visibleValidationError: String? {
        // Keep a new, untouched form quiet, but explain a disabled save after
        // the user has started entering an objective or an allowance.
        guard !model.draftObjective.isEmpty || !model.draftModelCallBudget.isEmpty || !model.draftTokenBudget.isEmpty else { return nil }
        return model.draftValidationError
    }

    private func budgetField(_ title: String, placeholder: String, value: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium))
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
                .disabled(model.isSaving)
                .accessibilityLabel(title + " allowance").accessibilityIdentifier(id)
        }
    }
}
