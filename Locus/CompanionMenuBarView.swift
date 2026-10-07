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
    @Environment(\.dismiss) private var dismiss
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
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.locus(.icon)).keyboardShortcut(.cancelAction).help("Close companion")
                .accessibilityLabel("Close companion").accessibilityIdentifier("companion.menubar.close")
            }
            .padding(12)
            Divider()
            if tab == .chat {
                CompanionInspectorTab(revealMainWindow: revealMainWindow, tracksPointer: false)
            } else {
                CompanionActivityCardsView(revealMainWindow: revealMainWindow)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your companion")
        .accessibilityIdentifier("companion.menubar.popover")
        .onAppear { presenter.install(openWindow) }
        .onExitCommand { dismiss() }
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

    private func revealMainWindow() {
        dismiss()
        presenter.install(openWindow)
        presenter.present()
    }
}
