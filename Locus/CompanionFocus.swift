import SwiftUI

struct CompanionFocusSession: Decodable, Equatable {
    struct Step: Decodable, Equatable { let title: String; let evidence: String; let completed: Bool }
    let mode: String
    let minutes: Int
    let steps: [Step]
    let state: String
    let startedAt: Double
    let elapsedSeconds: Double
    enum CodingKeys: String, CodingKey {
        case mode, minutes, steps, state
        case startedAt = "started_at", elapsedSeconds = "elapsed_seconds"
    }
    func remaining(at now: Date) -> TimeInterval {
        max(0, Double(minutes * 60) - elapsedSeconds - (state == "running" ? max(0, now.timeIntervalSince1970 - startedAt) : 0))
    }
    static func from(_ goal: PersistentGoal?) -> Self? {
        guard let value = goal?.execution["companion_session"], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func prompt(_ action: String, objective: String) -> String {
        let progress = steps.map { "\($0.completed ? "Completed (user reported)" : "Pending"): \($0.title)\($0.evidence.isEmpty ? "" : " — " + $0.evidence)" }.joined(separator: "\n")
        return """
        We agreed on a \(minutes)-minute \(mode) session. Deliverable: \(objective)
        Checkpoints:\n\(progress)
        Requested step: \(action).
        Work only on this requested step. For learning, explain one concept at a time, ask one exercise, and wait for my attempt. Give hints before solutions; only reveal an answer when I explicitly request it. Distinguish my reported progress from independently checked evidence. Do not begin autonomous continuation or mark learning complete solely because time elapsed.
        """
    }
}

struct CompanionFocusView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var goals: GoalModel
    let sessionID: String
    let sendPrompt: (String) async throws -> Void
    @State private var objective = ""
    @State private var checkpointText = ""
    @State private var mode = "focus"
    @State private var minutes = 30
    @State private var evidence: [Int: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var hintRequested = false
    private var goal: PersistentGoal? { goals.goal(for: sessionID) }
    private var session: CompanionFocusSession? { .from(goal) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Focus & learning").font(.headline)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if let session, let goal {
                    Text(goal.objective).font(.subheadline.bold())
                    TimelineView(.periodic(from: .now, by: 1)) { time in
                        let remaining = Int(session.remaining(at: time.date))
                        Text(goal.status.isTerminal ? "Session ended" : remaining == 0
                             ? "Time for a check-in. Review your progress and finish when ready."
                             : "\(remaining / 60):\(String(format: "%02d", remaining % 60)) remaining · \(session.state)")
                            .font(.caption).monospacedDigit().accessibilityIdentifier("companion.focus.time")
                    }
                    ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(step.title, systemImage: step.completed ? "checkmark.circle" : "circle")
                            if step.completed {
                                Text(step.evidence).font(.caption).foregroundStyle(.secondary)
                            } else if !goal.status.isTerminal && session.state != "finished" {
                                TextField("What did you produce or learn?", text: Binding(get: { evidence[index] ?? "" }, set: { evidence[index] = $0 }))
                                Button("Record progress") { perform { try await goals.updateCompanionSession(sessionID: sessionID,
                                    operation: "checkpoint", index: index, evidence: evidence[index]) } }
                                    .disabled((evidence[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if !goal.status.isTerminal && session.state != "finished" {
                        if session.mode == "learning" {
                            HStack {
                                Button("Explain") { ask("Explain the next pending checkpoint", session, goal) }
                                Button("Exercise") { hintRequested = false; ask("Offer one exercise for the next checkpoint, without its answer", session, goal) }
                                Button("Hint") { hintRequested = true; ask("Give one hint for my current exercise, without revealing the answer", session, goal) }
                                Button("Answer") { ask("I explicitly request the worked answer to the current exercise", session, goal) }.disabled(!hintRequested)
                            }
                        }
                        HStack {
                            Button(session.state == "paused" ? "Resume timer" : "Pause timer") {
                                perform { try await goals.updateCompanionSession(sessionID: sessionID,
                                    operation: session.state == "paused" ? "resume" : "pause") }
                            }
                            Button("Check in") { ask("Review the checkpoint evidence and suggest the next useful action", session, goal) }
                            Button("Finish") { perform { try await goals.updateCompanionSession(sessionID: sessionID, operation: "finish") } }
                        }
                    } else {
                        Text(goal.summary ?? "").font(.subheadline)
                        Text("Progress is reported by you. Time elapsed is not evidence of completion.").font(.caption).foregroundStyle(.secondary)
                        Button("Summarize learning") { ask("Summarize what the recorded evidence shows, remaining gaps, and one next practice step", session, goal) }
                        Button("Start another session") { objective = ""; checkpointText = ""; showNewSession = true }
                    }
                } else if goal?.status.isTerminal == false {
                    Text("This chat already has an unfinished goal. Finish or cancel it before starting a focus session.")
                } else { sessionEditor }
                Text("The timer runs while Locus is open and resumes from saved timestamps. It never starts work automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).disabled(busy || goals.isSaving)
        }
        .frame(minWidth: 360, idealWidth: 450, minHeight: 300)
        .task(id: sessionID) { _ = await goals.refresh(sessionID: sessionID) }
        .sheet(isPresented: $showNewSession) { sessionEditor.padding(20).frame(width: 400) }
    }
    @State private var showNewSession = false
    private var sessionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Session", selection: $mode) { Text("Focus").tag("focus"); Text("Learning").tag("learning") }.pickerStyle(.segmented)
            TextField("Agree on a small deliverable", text: $objective)
            Stepper("\(minutes) minutes", value: $minutes, in: 1...240, step: 5)
            Text("Checkpoints (one per line)").font(.caption)
            TextEditor(text: $checkpointText).frame(height: 100).border(.quaternary)
            Button("Agree & start") { perform { try await create(); showNewSession = false } }
                .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checkpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || goals.isSaving)
        }
    }
    private func create() async throws {
        guard let profile = app.primaryCompanionProfile,
              app.companionConversation?.id == sessionID,
              !app.savedAgentConversationState(sessionID).busy else { throw SavedAgentConversationError.unavailable("Open your idle Companion chat to start a session.") }
        let dispatch = try app.savedAgentProfileDispatch(profileID: profile.id, mode: .ask, sessionID: sessionID)
        let detail = try await app.backend.get("/api/sessions/\(sessionID)", as: SessionDetailResponse.self)
        var route = detail.executionQueueContext
        route["provider"] = dispatch.provider; route["model"] = dispatch.profile.model
        route["provider_account_id"] = dispatch.accountID; route["runner"] = "solo"
        try await goals.createCompanionSession(sessionID: sessionID, objective: objective, mode: mode, minutes: minutes,
            checkpoints: checkpointText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, execution: route)
    }
    private func ask(_ action: String, _ session: CompanionFocusSession, _ goal: PersistentGoal) {
        perform { try await sendPrompt(session.prompt(action, objective: goal.objective)) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// A returning user sees a due check-in without reopening the session tool.
/// This only reads the canonical goal and never dispatches a turn.
struct CompanionFocusCheckInView: View {
    @EnvironmentObject private var goals: GoalModel
    let sessionID: String
    let openSession: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { time in
            if let goal = goals.goal(for: sessionID), !goal.status.isTerminal,
               let session = CompanionFocusSession.from(goal), session.state != "finished",
               session.remaining(at: time.date) <= 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "timer")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Time to check in").font(.subheadline.bold())
                        Text(goal.objective).font(.caption).lineLimit(2)
                        Text("Review your checkpoint evidence and choose the next step.").font(.caption).foregroundStyle(.secondary)
                        Button("Review session", action: openSession)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("companion.focus.checkIn")
            }
        }
        .task(id: sessionID) { _ = await goals.refresh(sessionID: sessionID) }
    }
}
