import AppKit
import SwiftUI

/// Lives beside the normal composer: the agent can keep working while the
/// person answers, and the answer draft belongs to the session, not this view.
struct OptionalQuestionPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var questions: OptionalQuestionModel
    let sessionID: String

    var body: some View {
        VStack(spacing: 8) {
            ForEach(questions.visibleRequests(sessionID: sessionID)) { request in
                OptionalQuestionCard(questions: questions, request: request, canResume: model.isBusy) {
                    model.useOptionalQuestionDraft(request)
                }
            }
        }
        .id(sessionID)
    }
}

private struct OptionalQuestionCard: View {
    @ObservedObject var questions: OptionalQuestionModel
    let request: OptionalQuestionRequest
    let canResume: Bool
    var useDraft: () -> Void
    @FocusState private var focusedControl: String?

    private var scope: String {
        OptionalQuestionModel.key(sessionID: request.sessionID, requestID: request.id)
    }
    private var isConnected: Bool { questions.connected[request.sessionID] != false }
    private var isSending: Bool { questions.sending.contains(scope) }
    private var hasDraft: Bool { questions.hasDraft(sessionID: request.sessionID, requestID: request.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(request.isOpen ? "Optional question" : "Optional answer", systemImage: "bubble.left")
                    .font(.locus(size: 12, weight: .semibold))
                Spacer()
                if request.isPending {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(at: context.date))
                            .font(.locus(size: 11))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .accessibilityIdentifier("optionalQuestion.countdown")
                    }
                }
            }
            if request.isOpen || hasDraft {
                Text(request.isPending
                     ? "Work continues while you answer. Skip uses the recommendations below for any unanswered questions."
                     : "This question is paused or finished. Your draft is still available for a follow-up.")
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(request.questions) { question in
                            questionRow(question)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = questions.errors[scope] {
                Text(error).font(.locus(size: 11)).foregroundStyle(LocusTheme.warningForeground)
                    .accessibilityIdentifier("optionalQuestion.error")
            }
            HStack(spacing: 10) {
                if request.isPending {
                    Button("Skip") {
                        _ = questions.respond(sessionID: request.sessionID, requestID: request.id, action: "skip")
                    }
                    .disabled(!isConnected || isSending)
                    .accessibilityIdentifier("optionalQuestion.skip")
                    if isSending { ProgressView().controlSize(.small) }
                } else {
                    Text(deliveryText)
                        .font(.locus(size: 11))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("optionalQuestion.delivery")
                    Spacer()
                    if request.status == "suspended" || request.deliveryStatus == "accepted" {
                        Button(request.status == "suspended" ? "Resume question" : "Resume delivery") {
                            questions.resume(sessionID: request.sessionID, requestID: request.id)
                        }
                        .disabled(!isConnected || !canResume)
                        .help(canResume ? "Restart the question timer" : "Resume the task before restarting this question")
                        .accessibilityIdentifier("optionalQuestion.resume")
                    }
                    if hasDraft {
                        Button("Use draft in follow-up", action: useDraft)
                            .accessibilityIdentifier("optionalQuestion.useDraft")
                    }
                    Button(hasDraft ? "Discard draft" : "Dismiss") {
                        questions.discardDraft(sessionID: request.sessionID, requestID: request.id)
                    }
                    .accessibilityIdentifier("optionalQuestion.dismiss")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .locusCard(radius: 13)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("optionalQuestion.panel")
        .onChange(of: focusedControl) { _, control in
            if control == nil { releaseLease() }
        }
        .task(id: scope) {
            // View values are rebuilt on every keystroke. A task tied to the
            // card identity keeps lease renewals on a steady cadence.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard focusedControl != nil, NSApplication.shared.isActive else { continue }
                questions.renewEditing(sessionID: request.sessionID, requestID: request.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            releaseLease()
        }
        .onDisappear { releaseLease() }
    }

    @ViewBuilder
    private func questionRow(_ question: OptionalAgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question).font(.locus(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let answer = question.answer {
                Label(([answer.selected?.joined(separator: ", "), answer.text]
                    .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "; "), systemImage: "checkmark.circle")
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.inkSoft)
            }
            if question.answer == nil || draft(question).hasContent {
                ForEach(question.options) { option in
                    Button {
                        var value = draft(question)
                        if question.multiSelect {
                            if !value.selected.insert(option.id).inserted { value.selected.remove(option.id) }
                        } else { value.selected = [option.id] }
                        update(value, question: question)
                        focusedControl = question.id + "/" + option.id
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: draft(question).selected.contains(option.id)
                                  ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.locus(size: 11, weight: .medium))
                                if !option.description.isEmpty {
                                    Text(option.description).font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .focused($focusedControl, equals: question.id + "/" + option.id)
                    .accessibilityIdentifier("optionalQuestion.option.\(question.id).\(option.id)")
                }
                TextField("Your answer or extra detail", text: Binding(
                    get: { draft(question).text },
                    set: { value in
                        var next = draft(question)
                        // SwiftUI can write the same value when a field gains
                        // focus. That is not an edit and must not pause time.
                        guard value != next.text else { return }
                        next.text = value
                        update(next, question: question)
                    }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.locus(size: 12))
                .focused($focusedControl, equals: question.id + "/text")
                .accessibilityIdentifier("optionalQuestion.entry.\(question.id)")
            }
            if question.answer == nil {
                Text("Recommendation: \(question.recommendation)")
                    .font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("optionalQuestion.recommendation.\(question.id)")
                if request.isPending {
                    Button("Submit answer") {
                        _ = questions.respond(sessionID: request.sessionID, requestID: request.id, questionID: question.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!draft(question).hasContent || !isConnected || isSending)
                    .accessibilityIdentifier("optionalQuestion.answer.\(question.id)")
                }
            }
        }
    }

    private func draft(_ question: OptionalAgentQuestion) -> OptionalQuestionDraft {
        questions.draft(sessionID: request.sessionID, requestID: request.id, questionID: question.id)
    }

    private func update(_ value: OptionalQuestionDraft, question: OptionalAgentQuestion) {
        questions.updateDraft(value, sessionID: request.sessionID, requestID: request.id, questionID: question.id)
        questions.beginEditing(sessionID: request.sessionID, requestID: request.id)
    }

    private func releaseLease() {
        questions.endEditing(sessionID: request.sessionID, requestID: request.id)
    }

    private func countdown(at date: Date) -> String {
        if !isConnected { return "Reconnecting… draft saved" }
        if request.paused { return "Timer paused while editing" }
        let seconds = request.remainingSeconds(at: date, connected: isConnected)
        return seconds > 0 ? "Recommendations in \(seconds)s" : "Waiting for saved recommendation…"
    }

    private var deliveryText: String {
        if request.deliveryStatus == "applied" || request.appliedAt != nil { return "Answer applied to the agent’s work." }
        if request.deliveryStatus == "accepted" { return "Answer accepted. Waiting for the agent to apply it." }
        switch request.status {
        case "superseded": return request.supersededReason ?? "This question is no longer needed."
        case "suspended": return "Paused with this task."
        case "defaulted": return "Time elapsed; recommendations selected."
        case "skipped": return "Unanswered questions used the recommendations."
        case "answered": return "Answer accepted."
        default: return "This question has finished."
        }
    }
}
