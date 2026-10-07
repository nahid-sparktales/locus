import SwiftUI

/// Preferences only. Runs, requests, seen state, and dismissals stay in ActivityCenterModel.
struct CompanionNotificationPolicy: Codable, Equatable {
    var enabledSources: Set<String> = Set(ActivityFilter.Kind.allCases.filter { $0 != .all }.map(\.rawValue))
    var quietHoursEnabled = false
    var quietStartHour = 22
    var quietEndHour = 8
    var snoozedUntil: [String: Date] = [:]

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        return quietStartHour == quietEndHour || (quietStartHour < quietEndHour
            ? hour >= quietStartHour && hour < quietEndHour
            : hour >= quietStartHour || hour < quietEndHour)
    }
    func includes(_ kind: ActivityFilter.Kind) -> Bool { enabledSources.contains(kind.rawValue) }
    func isSnoozed(_ id: String, at date: Date = .now) -> Bool { (snoozedUntil[id] ?? .distantPast) > date }
}

struct CompanionActivityCardsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @EnvironmentObject private var sessions: SessionCatalogModel
    @State private var preferences = false
    @Environment(\.dismiss) private var dismiss
    var revealMainWindow: () -> Void = {}
    private var snapshot: CompanionMenuBarActivity {
        CompanionMenuBarActivity(profileID: app.primaryCompanionProfile?.id,
            workspace: app.companionWorkspacePath, sessionsByID: sessions.snapshot.sessionsByID,
            runs: activity.visibleActivityRuns, attentionItems: activity.attentionItems,
            unreadRunIDs: Set(activity.visibleActivityRuns.filter { activity.activityIsUnseen($0) }.map(\.id)))
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = snapshot
            let requests = snapshot.attentionItems.filter { item in
                activity.companionNotificationPolicy.includes(ActivityFilter.Kind.kind(for: item,
                    run: activity.visibleActivityRuns.first { $0.id == item.runID }))
                    && !activity.companionNotificationPolicy.isSnoozed(item.runID ?? item.id, at: context.date)
            }
            let results = snapshot.unreadRuns.filter {
                activity.companionNotificationPolicy.includes(ActivityFilter.Kind.kind(for: $0))
                    && !activity.companionNotificationPolicy.isSnoozed($0.id, at: context.date)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Companion activity").font(.headline)
                        Spacer()
                        Button { preferences.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Notification preferences")
                    }
                    if preferences { policyEditor }
                    if activity.companionNotificationPolicy.isQuiet(at: context.date) {
                        Text("Quiet hours are active. Your requests remain available here.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = activity.refreshError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if requests.isEmpty && results.isEmpty {
                        Text("No new updates from your selected sources.").foregroundStyle(.secondary)
                    }
                    if !requests.isEmpty {
                        Text("Needs attention (\(requests.count))").font(.subheadline.bold())
                        ForEach(requests) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.subheadline.bold())
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Review request") {
                                        dismiss(); revealMainWindow()
                                        activity.openActivityCenter(focus: item.workflowExecutionID.map(ActivityCenterModel.Focus.workflow)
                                            ?? item.runID.map(ActivityCenterModel.Focus.run))
                                    }
                                    snooze(item.runID ?? item.id)
                                }
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    ForEach(ActivityFilter.Kind.allCases.filter { $0 != .all }) { kind in
                        let group = results.filter { ActivityFilter.Kind.kind(for: $0) == kind }
                        if !group.isEmpty {
                            DisclosureGroup("\(kind.rawValue) · \(group.count) new \(group.count == 1 ? "result" : "results")") {
                                ForEach(group) { run in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(ChatTranscriptBuilder.displayUserText(run.request)).lineLimit(2).font(.subheadline)
                                        Text(run.state == "completed" ? "Finished and ready for your review." : "Work stopped and may need recovery.")
                                            .font(.caption).foregroundStyle(.secondary)
                                        HStack {
                                            Button("Review result") { dismiss(); revealMainWindow(); app.openActivityRun(run) }
                                            snooze(run.id)
                                        }
                                    }.padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    if !snapshot.inProgressRuns.isEmpty {
                        DisclosureGroup("Work in progress · \(snapshot.inProgressRuns.count)") {
                            ForEach(snapshot.inProgressRuns) { run in
                                Button(ChatTranscriptBuilder.displayUserText(run.request)) {
                                    dismiss(); revealMainWindow(); app.openActivityRun(run)
                                }.lineLimit(2).font(.caption)
                            }
                        }
                    }
                    Button("Refresh") { Task { await activity.refreshActivityRuns(announceFailure: false) } }
                        .disabled(activity.isRefreshing)
                    Button("Show all activity") { dismiss(); revealMainWindow(); activity.openActivityCenter() }
                }.padding(16)
            }
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 240)
        .task { await activity.refreshActivityRuns(announceFailure: false) }
    }
    private func snooze(_ id: String) -> some View {
        Menu("Snooze") {
            ForEach([15, 60, 240], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    activity.snoozeCompanionActivity(id, until: .now.addingTimeInterval(Double(minutes * 60)))
                }
            }
        }.font(.caption)
    }
    private var policyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ActivityFilter.Kind.allCases.filter { $0 != .all }) { kind in
                Toggle(kind.rawValue, isOn: Binding(get: { activity.companionNotificationPolicy.includes(kind) }, set: { enabled in
                    var policy = activity.companionNotificationPolicy
                    if enabled { policy.enabledSources.insert(kind.rawValue) } else { policy.enabledSources.remove(kind.rawValue) }
                    activity.updateCompanionNotificationPolicy(policy)
                }))
            }
            Toggle("Quiet hours", isOn: policyBinding(\.quietHoursEnabled))
            if activity.companionNotificationPolicy.quietHoursEnabled {
                HStack {
                    Picker("From", selection: policyBinding(\.quietStartHour)) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Picker("Until", selection: policyBinding(\.quietEndHour)) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                }
            }
            Button("Show snoozed updates") {
                var policy = activity.companionNotificationPolicy; policy.snoozedUntil = [:]
                activity.updateCompanionNotificationPolicy(policy)
            }.disabled(activity.companionNotificationPolicy.snoozedUntil.isEmpty)
            Text("Uses this Mac’s local time. Snoozing never resolves an approval or marks a result read.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func policyBinding<Value>(_ key: WritableKeyPath<CompanionNotificationPolicy, Value>) -> Binding<Value> {
        Binding(get: { activity.companionNotificationPolicy[keyPath: key] }, set: { value in
            var policy = activity.companionNotificationPolicy; policy[keyPath: key] = value
            activity.updateCompanionNotificationPolicy(policy)
        })
    }
}
