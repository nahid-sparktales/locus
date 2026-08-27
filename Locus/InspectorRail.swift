import Foundation
import SwiftUI

/// The always-visible right rail. Collapsing the inspector no longer empties
/// the window edge: Side Chat, Overview, Terminal, Browser, and Notes stay within reach,
/// while the vertical-ellipsis menu restores every additional workspace panel,
/// including Model Router and Proxies.
/// The panel opens to the rail's left. Attention badges
/// live on the icons, so a run can ask for eyes without the panel being open.
struct InspectorRail: View {
    @EnvironmentObject private var model: AppModel
    @State private var hoveredTab: InspectorTab?

    /// Direct rail destinations stay one click away. The remaining workspace
    /// panels live in the overflow menu instead of disappearing from the UI.
    static let menuTabs = InspectorTab.workspaceTabs.filter {
        $0 != .terminal && $0 != .notes
    }

    var body: some View {
        VStack(spacing: 4) {
            moreMenu
            sideChatButton
            railTab(.plan)
            railTab(.terminal)
            railTab(.preview)
            railTab(.notes)
            Spacer(minLength: 0)
            zoomButton
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .locusSurface(.structural)
        .overlay(alignment: .leading) {
            Rectangle().fill(LocusTheme.line).frame(width: 1)
        }
    }

    private var sideChatButton: some View {
        let selected = model.splitViewActive
        return Button {
            withAnimation(LocusMotion.spatial) {
                model.toggleSplitView()
            }
        } label: {
            Image(
                systemName: selected
                    ? "rectangle.split.2x1.fill"
                    : "rectangle.split.2x1"
            )
            .font(.locus(size: 13, weight: .medium))
            .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
            .frame(width: 34, height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LocusTheme.ink.opacity(0.09))
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(LocusTheme.signalDeep)
                        .frame(width: 2, height: 14)
                        .offset(x: -3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .help(selected ? "Close Side Chat" : "Open Side Chat")
        .accessibilityLabel(selected ? "Close Side Chat" : "Open Side Chat")
        .accessibilityValue(selected ? "Open" : "Closed")
        .accessibilityIdentifier("inspector.rail.sideChat")
    }

    private var zoomButton: some View {
        Button {
            withAnimation(LocusMotion.spatial) {
                model.toggleInspectorZoom()
            }
        } label: {
            Image(
                systemName: model.inspectorZoomed
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
            .font(.locus(size: 12, weight: .medium))
            .foregroundStyle(LocusTheme.muted)
            .frame(width: 32, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.locus())
        .help(model.inspectorZoomed ? "Restore panel (⌘⌥E)" : "Expand panel (⌘⌥E)")
        .accessibilityLabel(model.inspectorZoomed ? "Restore panel" : "Expand panel")
        .accessibilityIdentifier("inspector.zoom")
    }

    private func railTab(_ tab: InspectorTab) -> some View {
        let selected = !model.inspectorCollapsed && model.inspectorTab == tab
        let hovered = hoveredTab == tab
        return Button {
            withAnimation(LocusMotion.spatial) {
                model.toggleInspectorTab(tab)
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.locus(size: 13, weight: .medium))
                .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
                .overlay(alignment: .topTrailing) {
                    InspectorTabBadge(tab: tab)
                }
                .frame(width: 34, height: 32)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LocusTheme.ink.opacity(0.09))
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LocusTheme.ink.opacity(0.045))
                    }
                }
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule()
                            .fill(LocusTheme.signalDeep)
                            .frame(width: 2, height: 14)
                            .offset(x: -3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .onHover { isInside in hoveredTab = isInside ? tab : nil }
        .help(tab.title)
        .accessibilityLabel("\(tab.title) inspector")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("inspector.rail.\(tab.rawValue)")
    }

    private var moreMenu: some View {
        Menu {
            ForEach(Self.menuTabs) { tab in
                Button(menuTitle(for: tab)) {
                    withAnimation(LocusMotion.spatial) {
                        model.selectInspectorTab(tab)
                    }
                }
                .accessibilityIdentifier("inspector.rail.menu.\(tab.rawValue)")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 12, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(LocusTheme.muted)
                .overlay(alignment: .topTrailing) {
                    // Changes lives in this menu, so its unseen dot surfaces
                    // here — the count itself waits in the menu title.
                    if model.changesHaveUnseenUpdate {
                        Circle()
                            .fill(LocusTheme.coral)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -3)
                    }
                }
                .frame(width: 34, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 32)
        .help("More panels")
        .accessibilityLabel("More panels")
        .accessibilityIdentifier("inspector.rail.more")
    }

    private func menuTitle(for tab: InspectorTab) -> String {
        if tab == .changes, model.changedFileCount > 0 {
            return "\(tab.title) (\(model.changedFileCount))"
        }
        if tab == .runs { return "Team Runs" }
        if tab == .router { return "Model Router" }
        return tab.title
    }

}

/// Workspace-level actions sit beside the model picker in the conversation
/// header. This keeps them separate from the inspector's panel picker.
struct WorkspaceActionsMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var createBranchPresented = false
    @State private var branchName = ""

    var body: some View {
        Menu {
            if model.currentExecutionEnvironment == .worktree {
                Button("Hand Off to Local") { model.handoffCurrentChat(to: .local) }
                    .disabled(model.isBusy || model.hasPendingPermission)
                if model.activeTaskRecord?.branch == nil {
                    Button("Create Branch Here…") { createBranchPresented = true }
                        .disabled(model.isBusy || model.hasPendingPermission)
                }
                if let task = model.activeTaskRecord,
                   !FileManager.default.fileExists(atPath: task.executionPath)
                {
                    Button("Restore Worktree") { model.restoreActiveTaskCheckout() }
                }
            } else if model.isGitRepository {
                Button("Hand Off to Worktree") { model.handoffCurrentChat(to: .worktree) }
                    .disabled(model.isBusy || model.hasPendingPermission)
            }
            if model.activeTaskRecord != nil {
                Button("Open Checkout") { model.openActiveTaskCheckout() }
                Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
            }
            Divider()
            // ⌘⇧K lives on the app menu's Clear Chat only — declaring it here
            // as well would register the same shortcut twice.
            Button("Clear Chat…") { model.requestClearChat() }
                .disabled(model.isBusy || model.hasPendingPermission)
                .accessibilityIdentifier("workspace.actions.clearChat")
            Menu("Start Worktree Chat From") {
                Button("Current HEAD") {
                    model.newWorktreeSession(in: model.workspacePath, baseRef: "HEAD")
                }
                .accessibilityIdentifier("workspace.actions.worktree.head")
                ForEach(model.localBranches, id: \.self) { branch in
                    Button(branch) {
                        model.newWorktreeSession(in: model.workspacePath, baseRef: branch)
                    }
                    .accessibilityIdentifier("workspace.actions.worktree.branch.\(branch)")
                }
            }
            .disabled(!model.isGitRepository)
            .accessibilityIdentifier("workspace.actions.newWorktreeSession")
            Button("Start New Local Chat") {
                model.newSession(in: model.workspacePath, environment: .local)
            }
            .accessibilityIdentifier("workspace.actions.newLocalSession")
            Button(model.splitViewActive ? "Close Second Chat Pane" : "Split Chat View") {
                model.toggleSplitView()
            }
            .accessibilityIdentifier("workspace.actions.splitView")
            Divider()
            Menu("Export Current Session") {
                ForEach(ChatExportFormat.allCases) { format in
                    Button("\(format.title)…") { model.exportCurrentSession(format: format) }
                }
            }
            .disabled(!model.sessions.contains { $0.id == model.currentSessionID })
            .accessibilityIdentifier("workspace.actions.export")
            Divider()
            Picker("Tool activity", selection: Binding(
                get: { model.toolActivityVisibility },
                set: { model.toolActivityVisibility = $0 }
            )) {
                ForEach(ToolActivityVisibility.allCases) { visibility in
                    Text(visibility.title)
                        .tag(visibility)
                        .accessibilityIdentifier(
                            "workspace.actions.toolActivity.\(visibility.rawValue)"
                        )
                }
            }
            .pickerStyle(.inline)
            Picker("Thinking", selection: Binding(
                get: { model.thinkingVisibility },
                set: { model.thinkingVisibility = $0 }
            )) {
                ForEach(ThinkingVisibility.allCases) { visibility in
                    Text(visibility.title)
                        .tag(visibility)
                        .accessibilityIdentifier(
                            "workspace.actions.thinking.\(visibility.rawValue)"
                        )
                }
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Header controls") {
                Toggle("Team progress", isOn: Binding(
                    get: { model.showTeamProgressInHeader },
                    set: { model.showTeamProgressInHeader = $0 }
                ))
                .accessibilityIdentifier("workspace.actions.showTeamProgress")
                Toggle("Context window", isOn: Binding(
                    get: { model.showContextUsageInHeader },
                    set: { model.showContextUsageInHeader = $0 }
                ))
                .accessibilityIdentifier("workspace.actions.showContextUsage")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 14, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 32, height: 32)
                .background(LocusTheme.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .help("Workspace actions")
        .accessibilityLabel("Workspace actions")
        .accessibilityIdentifier("workspace.actions")
        .alert("Create Branch in Worktree", isPresented: $createBranchPresented) {
            TextField("feature/name", text: $branchName)
                .accessibilityIdentifier("worktree.branchName")
            Button("Cancel", role: .cancel) { branchName = "" }
            Button("Create") {
                model.createBranchForActiveTask(branchName)
                branchName = ""
            }
            .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The worktree is detached until you deliberately create a branch.")
        }
    }
}
