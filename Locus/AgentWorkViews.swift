import SwiftUI

extension AgentWorkSource {
    @MainActor static func board(_ card: BoardCard, store: BoardStore) -> Self {
        .init(kind: "board", sourceID: card.id.uuidString, workspace: store.workspacePath,
              title: card.title, prompt: store.chatPrompt(for: card), agentIDs: card.agentIDs ?? [])
    }
    static func calendar(_ event: LocusCalendarEntry, workspace: String) -> Self {
        .init(kind: "calendar", sourceID: event.isLocal ? event.id : "\(event.calendarID):\(event.id):\(event.startDate.timeIntervalSince1970)", workspace: workspace, title: event.title,
              prompt: "\(event.title)\n\n\(event.notes)", agentIDs: event.agentIDs, suggestedDate: event.startDate)
    }
}

extension AppModel {
    var agentWorkWorkspace: String {
        agentWorldOwnsPresentations && agentWorld.activeScreen != nil ? agentWorld.workspace : workspacePath
    }
}

struct AgentWorkPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @EnvironmentObject private var schedules: ScheduleModel
    @Environment(\.locusViewColors) private var colors
    @ObservedObject private var ledger = AgentWorkLedger.shared
    @State private var assignmentSource: AgentWorkSource?
    @State private var result: OrchestrationRun?
    @State private var openingSavedRun = false
    @State private var openError: String?
    let source: AgentWorkSource
    var prepareAssignment: (() -> AgentWorkSource?)? = nil
    private var assignment: AgentWorkRecord? { ledger.latest(for: source) }
    private var run: OrchestrationRun? { activity.activityRuns.first { $0.id == assignment?.runID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Agent work", systemImage: "sparkles").font(.locus(size: 12, weight: .semibold))
                Spacer()
                if let assignment { Text(assignment.status).font(.locus(size: 11)).foregroundStyle(colors.signalDeep) }
            }
            if let assignment {
                Text(agentTeams.agentProfiles.first(where: { $0.id == assignment.profileID })?.name ?? "Saved agent")
                    .font(.locus(size: 12, weight: .medium))
                if let date = assignment.scheduledAt, assignment.runID == nil {
                    Text(date, format: .dateTime.month().day().hour().minute()).font(.locus(size: 11))
                }
                if let error = assignment.error ?? ledger.error {
                    Text(error).font(.locus(size: 11)).foregroundStyle(colors.warning).textSelection(.enabled)
                }
                HStack {
                    if let run {
                        Button(run.state == "completed" ? "Review result" : "View progress") {
                            if run.state == "completed" { result = run }
                            else { activity.openActivityCenter(focus: .run(run.id)); model.agentWorld.requestActivityCenter() }
                        }.buttonStyle(.locus(.primary))
                    }
                    if run == nil, assignment.runID != nil {
                        Button(openingSavedRun ? "Opening…" : "Open saved work") { openSavedRun() }
                            .buttonStyle(.locus()).disabled(openingSavedRun)
                    }
                    if assignment.runID == nil, let id = assignment.scheduleID, let task = schedules.scheduledTasks.first(where: { $0.id == id }) {
                        Button(task.enabled ? "Pause schedule" : "Resume schedule") {
                            schedules.setScheduleEnabled(task, enabled: !task.enabled)
                        }.buttonStyle(.locus()).disabled(schedules.changingEnabledIDs.contains(id))
                    }
                    if ["uncertain", "preparing"].contains(assignment.state) {
                        Button("Check activity") { activity.openActivityCenter(); model.agentWorld.requestActivityCenter() }.buttonStyle(.locus())
                    }
                    if assignment.canStartAgain {
                        Button("New assignment") { beginAssignment() }.buttonStyle(.locus())
                    }
                }
                if let openError { Text(openError).font(.locus(size: 11)).foregroundStyle(colors.warning) }
            } else {
                if let error = ledger.error { Text(error).font(.locus(size: 11)).foregroundStyle(colors.warning) }
                Text("Choose an agent to start this task or schedule it for later.")
                    .font(.locus(size: 11)).foregroundStyle(colors.muted)
                Button("Assign work") { beginAssignment() }.buttonStyle(.locus(.primary))
                    .accessibilityIdentifier("agentWork.assign")
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 12))
        .locusSheet(item: $assignmentSource) { AgentWorkAssignmentSheet(source: $0).modifier(LocusWorldSheetTheme()) }
        .locusSheet(item: $result) { run in
            ActivityResultReader(run: run, title: assignment?.title ?? source.title,
                agentName: agentTeams.agentProfiles.first(where: { $0.id == assignment?.profileID })?.name ?? "Agent",
                onBack: { result = nil })
                .frame(minWidth: 640, idealWidth: 900, minHeight: 560, idealHeight: 720)
        }
        .onReceive(schedules.$scheduledTasks) { tasks in ledger.reconcile(runs: activity.activityRuns, schedules: tasks) }
        .task { await schedules.refreshScheduledTasks(announceFailure: false); await activity.refreshActivityRuns(announceFailure: false) }
    }
    private func beginAssignment() {
        if let prepareAssignment { assignmentSource = prepareAssignment() }
        else { assignmentSource = source }
    }

    private func openSavedRun() {
        guard let id = assignment?.runID, !openingSavedRun else { return }
        openingSavedRun = true; openError = nil
        Task { @MainActor in
            defer { openingSavedRun = false }
            do {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let segment = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
                let saved = try await model.backend.get("/api/runs/\(segment)", as: OrchestrationRun.self)
                guard saved.id == id, saved.workspaceRoot.map(BoardStore.canonicalWorkspace) == BoardStore.canonicalWorkspace(source.workspace) else {
                    throw AgentWorldError.unavailable("This saved work belongs to another project.")
                }
                ledger.reconcile(runs: [saved], schedules: schedules.scheduledTasks)
                if saved.state == "completed" { result = saved }
                else { activity.openActivityCenter(focus: .run(saved.id)); model.agentWorld.requestActivityCenter() }
            } catch { openError = "Couldn’t open saved work: \(error.localizedDescription)" }
        }
    }

}

struct AgentWorkAssignmentSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locusViewColors) private var colors
    let source: AgentWorkSource
    @State private var agentID: UUID?
    @State private var prompt = ""
    @State private var scheduled = false
    @State private var date = Date().addingTimeInterval(3600)
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Assign agent work", systemImage: "sparkles").font(.locus(size: 20, weight: .semibold))
            Text(source.title).font(.locus(size: 13)).foregroundStyle(colors.muted)
            Picker("Agent", selection: $agentID) {
                Text("Choose an agent").tag(UUID?.none)
                ForEach(agentTeams.agentProfiles) { profile in Text("@\(profile.name)").tag(Optional(profile.id)) }
            }.accessibilityIdentifier("agentWork.agent")
            Text("Instructions").font(.locus(size: 12, weight: .semibold))
            TextEditor(text: $prompt).font(.locus(size: 13)).scrollContentBackground(.hidden)
                .padding(10).frame(minHeight: 160, maxHeight: 260)
                .background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("agentWork.instructions")
            Picker("When", selection: $scheduled) {
                Text("Start now").tag(false); Text("Schedule").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("agentWork.when")
            if scheduled {
                DatePicker("Start", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Text("Keep Locus running to start scheduled work.").font(.locus(size: 11)).foregroundStyle(colors.muted)
            }
            if let error { Text(error).font(.locus(size: 12)).foregroundStyle(colors.warning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.locus())
                Spacer()
                if submitting { ProgressView().controlSize(.small) }
                Button(scheduled ? "Schedule work" : "Start work") { submit() }
                    .buttonStyle(.locus(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(agentID == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                    .accessibilityIdentifier("agentWork.submit")
            }
        }
        .padding(24).frame(width: 520).foregroundStyle(colors.ink).background(colors.panel)
        .disabled(submitting).interactiveDismissDisabled(submitting)
        .onAppear {
            prompt = source.prompt
            let tagged = source.agentIDs.filter { id in agentTeams.agentProfiles.contains { $0.id == id } }
            agentID = tagged.count == 1 ? tagged.first : nil
            if let proposed = source.suggestedDate, proposed > Date() { date = proposed; scheduled = true }
        }
    }

    private func submit() {
        guard let agentID else { return }
        submitting = true; error = nil
        Task { @MainActor in
            defer { submitting = false }
            do {
                try await model.startAgentWork(source, profileID: agentID, prompt: prompt, at: scheduled ? date : nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
