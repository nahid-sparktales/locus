import AppKit
import SwiftUI

/// A read-only projection of existing activity, independent of the Activity
/// Center's current filter. Opening this view does not acknowledge notifications.
struct CompanionMenuBarActivity {
    let attentionItems: [AttentionItem]
    let unreadRuns: [OrchestrationRun]
    let inProgressRuns: [OrchestrationRun]
    var notificationCount: Int { attentionItems.count + unreadRuns.count }

    init(profileID: UUID?, workspace: String, sessionsByID: [String: SessionSummary],
         runs: [OrchestrationRun], attentionItems: [AttentionItem], unreadRunIDs: Set<String>) {
        guard let profileID else {
            self.attentionItems = []; unreadRuns = []; inProgressRuns = []
            return
        }
        let workspace = SessionSummary.canonicalWorkspacePath(workspace)
        var latest: [String: OrchestrationRun] = [:]
        for run in runs {
            if let previous = latest[run.id] {
                let previousIsTerminal = TeamRunState(rawValue: previous.state)?.isTerminal == true
                let currentIsTerminal = TeamRunState(rawValue: run.state)?.isTerminal == true
                // Match the companion summary: restored or delayed running
                // samples cannot resurrect a terminal run with the same ID.
                if previousIsTerminal && !currentIsTerminal { continue }
                if currentIsTerminal && !previousIsTerminal { latest[run.id] = run; continue }
                if (previous.lastSequence, previous.updatedAt, previous.state, previous.request)
                    >= (run.lastSequence, run.updatedAt, run.state, run.request) { continue }
            }
            latest[run.id] = run
        }
        let owned = latest.values.filter {
            CompanionActivitySummary.includes($0, profileID: profileID, workspace: workspace, sessionsByID: sessionsByID)
        }
        let ownedRunIDs = Set(owned.map(\.id))
        var seenRequests = Set<String>()
        self.attentionItems = attentionItems.sorted {
            ($0.timestamp, $0.id, $0.detail) < ($1.timestamp, $1.id, $1.detail)
        }.filter { item in
            let belongs: Bool
            if let runID = item.runID, latest[runID] != nil {
                belongs = ownedRunIDs.contains(runID)
            } else if let sessionID = item.sessionID, let session = sessionsByID[sessionID] {
                belongs = session.savedAgentProfileID == profileID && session.belongsToWorkspace(workspace)
            } else { belongs = false }
            return belongs && seenRequests.insert(item.id).inserted
        }
        let requestRunIDs = Set(self.attentionItems.compactMap(\.runID))
        let sorted = owned.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        unreadRuns = sorted.filter {
            TeamRunState(rawValue: $0.state)?.isTerminal == true
                && unreadRunIDs.contains($0.id) && !requestRunIDs.contains($0.id)
        }
        inProgressRuns = sorted.filter {
            TeamRunState(rawValue: $0.state)?.isTerminal == false && !requestRunIDs.contains($0.id)
        }
    }
}

/// A temporary native presentation of the same companion panel and activity
/// stores. There is no menu-bar chat session, separate draft, or execution path.
struct CompanionMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @EnvironmentObject private var sessions: SessionCatalogModel
    @EnvironmentObject private var runtime: RuntimeStatusModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.openWindow) private var openWindow
    @StateObject private var windowHandle = CompanionMenuBarWindowHandle()
    @State private var tab = Tab.chat
    let presenter: MainWindowPresenter

    private enum Tab { case chat, activity }
    private var profile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == agentTeams.primaryCompanionID }
    }
    private var snapshot: CompanionMenuBarActivity {
        CompanionMenuBarActivity(profileID: profile?.id,
            workspace: profile.map { model.companionActivityWorkspacePath(profileID: $0.id) } ?? "",
            sessionsByID: sessions.snapshot.sessionsByID, runs: activity.visibleActivityRuns,
            attentionItems: activity.attentionItems,
            unreadRunIDs: Set(activity.visibleActivityRuns.filter { activity.activityIsUnseen($0) }.map(\.id)))
    }

    var body: some View {
        let snapshot = snapshot
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                tabButton(.chat, title: "Chat", symbol: "bubble.left.and.bubble.right")
                tabButton(.activity, title: snapshot.notificationCount == 0 ? "Activity" : "Activity (\(snapshot.notificationCount))",
                          symbol: "bell")
                Spacer(minLength: 0)
                Button { windowHandle.hide() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.locus(.icon)).help("Close companion")
                .accessibilityLabel("Close companion").accessibilityIdentifier("companion.menubar.close")
            }
            .padding(12)
            Divider()
            if tab == .chat {
                CompanionInspectorTab(revealMainWindow: revealMainWindow)
            } else {
                activityContent(snapshot)
            }
            Divider()
            HStack {
                Button { revealMainWindow() } label: {
                    Label("Open \(AppEdition.current.displayName)", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.locus()).keyboardShortcut("o")
                .accessibilityIdentifier("companion.menubar.open")
                Spacer()
                Menu {
                    Button("Configure Agent…") {
                        revealMainWindow()
                        model.presentConfigureAgent(draftText: "")
                    }.accessibilityIdentifier("companion.menubar.configure")
                    Button("Settings…") {
                        revealMainWindow()
                        model.presentSettings(.general)
                    }
                    Divider()
                    Button("Quit \(AppEdition.current.displayName)") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Locus options").accessibilityIdentifier("companion.menubar.options")
            }
            .font(.locus(size: 12)).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 440, height: 600)
        .background(colors.surfacePanel)
        .background(CompanionMenuBarWindowCapture(handle: windowHandle).frame(width: 0, height: 0))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your companion")
        .accessibilityIdentifier("companion.menubar.popover")
        .onAppear { presenter.install(openWindow) }
        .onExitCommand { windowHandle.hide() }
    }

    private func tabButton(_ selection: Tab, title: String, symbol: String) -> some View {
        Button { tab = selection } label: {
            Label(title, systemImage: symbol)
                .font(.locus(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 30)
                .background(tab == selection ? colors.surfaceStructural : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.locus(.quiet))
        .accessibilityAddTraits(tab == selection ? .isSelected : [])
        .accessibilityIdentifier(selection == .chat ? "companion.menubar.chat" : "companion.menubar.activity")
    }

    private func activityContent(_ snapshot: CompanionMenuBarActivity) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let profile {
                    Button {
                        revealMainWindow()
                        model.selectSavedAgent(profile)
                    } label: {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 64)
                    }
                    .buttonStyle(.locus(.icon)).accessibilityLabel("Open \(profile.name)’s profile")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile?.name ?? "Your companion").font(.locus(size: 18, weight: .semibold)).lineLimit(1)
                    Text("Notifications and work updates")
                        .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
                }
                Spacer(minLength: 0)
                Button { Task { await activity.refreshActivityRuns(announceFailure: false) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.locus(.icon)).disabled(activity.isRefreshing || !runtime.agentPhase.isOnline)
                .accessibilityLabel("Refresh activity")
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = activity.refreshError {
                        Text(error).font(.locus(size: 12)).foregroundStyle(colors.warning)
                    }
                    if !runtime.agentPhase.isOnline {
                        Text("Locus is disconnected. Showing the last available updates.")
                            .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
                    }
                    if snapshot.attentionItems.isEmpty && snapshot.unreadRuns.isEmpty && snapshot.inProgressRuns.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bell").font(.locus(size: 24)).foregroundStyle(colors.textTertiary)
                            Text(profile == nil ? "Set up your companion to see its activity." : "No new companion updates")
                                .font(.locus(size: 14, weight: .medium))
                            Text("Requests and new results appear here. Opening this popover does not mark them as read.")
                                .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
                        }
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    if !snapshot.attentionItems.isEmpty {
                        sectionTitle("Needs attention")
                        ForEach(snapshot.attentionItems) { item in
                            Button {
                                revealMainWindow()
                                activity.openActivityCenter(focus: item.workflowExecutionID.map(ActivityCenterModel.Focus.workflow)
                                    ?? item.runID.map(ActivityCenterModel.Focus.run))
                            } label: {
                                activityRow(title: item.title, detail: item.detail, symbol: "exclamationmark.circle",
                                            tint: colors.warning)
                            }
                            .buttonStyle(.locus(.card)).accessibilityIdentifier("companion.menubar.request.\(item.id)")
                        }
                    }
                    if !snapshot.unreadRuns.isEmpty {
                        sectionTitle("New results")
                        ForEach(snapshot.unreadRuns) { run in runButton(run) }
                    }
                    if !snapshot.inProgressRuns.isEmpty {
                        sectionTitle("Work in progress")
                        ForEach(snapshot.inProgressRuns) { run in runButton(run) }
                    }
                    Button("View all Locus activity") {
                        revealMainWindow()
                        activity.openActivityCenter()
                    }.buttonStyle(.locus()).padding(.vertical, 8)
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if runtime.agentPhase.isOnline { await activity.refreshActivityRuns(announceFailure: false) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.locus(size: 12, weight: .semibold)).foregroundStyle(colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func runButton(_ run: OrchestrationRun) -> some View {
        let state = TeamRunState(rawValue: run.state)
        let title = ChatTranscriptBuilder.displayUserText(run.request).split(separator: "\n").first.map(String.init)
            ?? "Companion task"
        return Button {
            revealMainWindow()
            model.openActivityRun(run)
        } label: {
            activityRow(title: title, detail: state?.title ?? run.state,
                        symbol: state == .completed ? "checkmark.circle" : state == .paused ? "pause.circle"
                            : state?.isTerminal == true ? "exclamationmark.circle" : "clock",
                        tint: state == .completed ? colors.success : state?.isTerminal == true ? colors.warning : colors.textSecondary)
        }
        .buttonStyle(.locus(.card)).accessibilityIdentifier("companion.menubar.run.\(run.id)")
    }

    private func activityRow(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.locus(size: 15)).foregroundStyle(tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.locus(size: 13, weight: .medium)).lineLimit(2)
                Text(detail).font(.locus(size: 11)).foregroundStyle(colors.textSecondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.locus(size: 10)).foregroundStyle(colors.textTertiary)
        }
        .multilineTextAlignment(.leading).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surfaceStructural, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func revealMainWindow() {
        windowHandle.hide()
        presenter.install(openWindow)
        presenter.present()
    }
}

/// Capture only this presentation's window; using NSApp.keyWindow could close
/// an unrelated document after an action has already focused the main scene.
@MainActor
private final class CompanionMenuBarWindowHandle: ObservableObject {
    weak var window: NSWindow?
    func hide() { window?.orderOut(nil) }
}

private struct CompanionMenuBarWindowCapture: NSViewRepresentable {
    let handle: CompanionMenuBarWindowHandle
    func makeNSView(context: Context) -> CaptureView { CaptureView(handle: handle) }
    func updateNSView(_ view: CaptureView, context: Context) {}
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.handle.window = nil }

    final class CaptureView: NSView {
        let handle: CompanionMenuBarWindowHandle
        init(handle: CompanionMenuBarWindowHandle) { self.handle = handle; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("CompanionMenuBarWindowCapture is programmatic") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); handle.window = window }
    }
}
