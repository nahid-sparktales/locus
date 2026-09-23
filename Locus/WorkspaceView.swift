import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @EnvironmentObject private var gitWorkspace: GitWorkspaceModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locusWorkspaceGeometry) private var workspaceGeometry
    @Environment(\.locusIsLiveResizing) private var isLiveResizing
    @State private var modelPickerPresented = false
    @State private var teamProgressPresented = false
    let sidebarVisible: Bool
    let showSidebar: () -> Void
    var presentsAgentOverview = true
    var openAgentOverview: (() -> Void)? = nil
    var compactHeader = false

    var body: some View {
        VStack(spacing: 0) {
            if model.agentCrewChatPresented, model.sidebarDestination == .agents {
                AgentCrewChatView(model: model.agentCrewChat, sidebarVisible: sidebarVisible, showSidebar: showSidebar)
                    .id(model.agentCrewChat.workspace)
            } else if presentsAgentOverview, let profile = model.savedAgentOverviewProfile {
                agentOverviewHeader
                SavedAgentInspectorView(profile: profile)
                    .id(profile.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let destination = model.emptySidebarDestination {
                if !sidebarVisible {
                    HStack {
                        HeaderIconButton(symbol: "sidebar.left", label: "Show sidebar",
                                         identifier: "workspace.showSidebar", action: showSidebar)
                        Spacer()
                    }
                    .padding(16)
                }
                ContentUnavailableView {
                    Label(destination == .agents ? "Choose an agent" : "Start a work chat",
                          systemImage: destination == .agents ? "person.2" : "bubble.left")
                } description: {
                    Text(destination == .agents
                         ? "Select an agent to see its connections, automations, and latest work."
                         : "Create a chat to start working in this workspace.")
                } actions: {
                    Button(destination == .agents ? "New agent" : "New chat") {
                        if destination == .agents { model.presentNewAgent() }
                        else { model.newSession() }
                    }
                    .accessibilityIdentifier("workspace.emptyDestination.action")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace.emptyDestination")
            } else {
                header
                contentArea
            }
        }
        .locusWorkspaceBackground()
        .locusSheet(isPresented: Binding(
            get: { activityCenter.activityCenterPresented && !model.agentWorldOwnsPresentations },
            set: { if !model.agentWorldOwnsPresentations { activityCenter.activityCenterPresented = $0 } }
        )) {
            ActivityCenterView()
                .appFeatureEnvironment(from: model)
                .frame(width: min(1120, max(320, workspaceGeometry.windowSize.width - 40)),
                       height: min(780, max(440, workspaceGeometry.windowSize.height - 40)))
        }
    }

    private var agentOverviewHeader: some View {
        HStack(spacing: 12) {
            if !sidebarVisible {
                HeaderIconButton(symbol: "sidebar.left", label: "Show sidebar",
                                 identifier: "workspace.showSidebar", action: showSidebar)
            }
            Label("Agent overview", systemImage: "person.crop.rectangle")
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(viewColors.inkSoft)
            Spacer()
        }
        .padding(.leading, compactHeader ? 12 : sidebarVisible ? 20 : 76)
        .padding(.trailing, compactHeader ? 10 : 18)
        .frame(height: compactHeader ? 42 : WorkspaceLayoutMetrics.toolbarHeight)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(viewColors.line).frame(height: 1) }
    }

    private var contentArea: some View {
        chatContent
            // A docked request overview owns the trailing side, so the card
            // never covers transcript text or the composer.
            .modifier(ConversationColumnDocking(
                workspaceWidth: workspaceGeometry.workspaceWidth,
                overview: workspaceGeometry.requestOverview
            ))
            // The parent VStack already proposes the space below the toolbar.
            .frame(maxHeight: .infinity)
        .clipped()
        .onExitCommand { model.dismissOverview() }
        .onChange(of: model.currentSessionID) {
            if model.isBusy { model.presentRequestOverview() }
            else { model.dismissOverview() }
        }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            switch model.agentRuntimePhase {
            case .recovering(let message):
                runtimeBanner(message, recovering: true)
            case .unavailable(let message):
                runtimeBanner(message, recovering: false)
            case .starting, .online:
                EmptyView()
            }

            if model.transcriptSearchPresented {
                TranscriptSearchBar()
                    .environmentObject(model)
            }

            ConversationView(streamingReply: model.streamingReply)
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()

            if shouldShowWorkStatus {
                WorkStatusStrip(streamingReply: model.streamingReply)
                    .environmentObject(model)
                    .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            }

            ComposerView()
        }
    }

    private var header: some View {
        HStack(spacing: compactHeader ? 8 : 12) {
            if !sidebarVisible {
                HeaderIconButton(
                    symbol: "sidebar.left",
                    label: "Show sidebar",
                    identifier: "workspace.showSidebar"
                ) {
                    withAnimation(LocusMotion.spatial) {
                        showSidebar()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                WorkspaceSessionTitle(sessionID: model.currentSessionID)

                if !compactHeader { HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.locus(size: 7, weight: .medium))
                        .accessibilityHidden(true)
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .accessibilityIdentifier("workspace.breadcrumb.path")
                    if let branch = gitWorkspace.gitBranch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.locus(size: 7))
                                .accessibilityHidden(true)
                            Text(branch)
                                .accessibilityLabel("Git branch \(branch)")
                                .accessibilityIdentifier("workspace.breadcrumb.gitBranch")
                        }
                    }
                }
                .font(.locus(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(viewColors.muted)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.breadcrumb")
                }
            }.lineLimit(1)

            Spacer()

            if !compactHeader, model.sidebarDestination == .agents,
               let profileID = model.savedAgentProfileID(for: model.currentSessionID),
               let profile = agentTeams.agentProfiles.first(where: { $0.id == profileID }) {
                Button {
                    if let openAgentOverview { openAgentOverview() }
                    else { model.selectSavedAgent(profile) }
                } label: {
                    Label("Overview", systemImage: "person.crop.rectangle")
                }
                .buttonStyle(.locus())
                .controlSize(.small)
                .help("Show \(profile.name)’s connections, automations, and latest result")
                .accessibilityIdentifier("workspace.agentOverview")
            }

            if model.showTeamProgressInHeader, agentTeams.selectedAgentTeam != nil {
                Button {
                    teamProgressPresented.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.locus(size: 12, weight: .medium))
                            .foregroundStyle(viewColors.inkSoft)
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(teamProgressColor)
                            .frame(width: 6, height: 6)
                            .overlay {
                                Circle().stroke(viewColors.panel, lineWidth: 1.5)
                            }
                            .offset(x: -3, y: 3)
                    }
                    .background(viewColors.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(viewColors.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.locus())
                .frame(width: 28, height: 28)
                .help("Team progress · \(teamProgressTitle)")
                .accessibilityLabel("Team progress, \(teamProgressTitle)")
                .accessibilityIdentifier("workspace.teamProgress")
                .popover(isPresented: $teamProgressPresented, arrowEdge: .top) {
                    TeamProgressPopover {
                        teamProgressPresented = false
                    }
                    .environmentObject(model)
                }
            }

            if model.showContextUsageInHeader {
                ContextUsageChip()
                    .environmentObject(model).fixedSize().lineLimit(1)
            }

            if model.activeTaskRecord != nil, landingFlow.taskHasChanges {
                Button("Review & Land") { landingFlow.prepareReviewAndLand() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(viewColors.ink)
                    .disabled(model.isBusy)
                    .help("Review this worktree's changes, checks, and landing destination")
                    .accessibilityIdentifier("workspace.reviewAndLand")
            }

            WorkspaceEffortPicker()
                .environmentObject(model)

            Button {
                modelPickerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(runtimeHealthColor)
                        .frame(width: 6, height: 6)
                    Text(model.modelPickerLabel)
                        .font(.locus(size: 9, weight: .semibold))
                        .lineLimit(1)
                    if model.modelSelectionLockReason != nil {
                        Image(systemName: "lock.fill")
                            .font(.locus(size: 8))
                            .foregroundStyle(viewColors.muted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(viewColors.white.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(viewColors.line, lineWidth: 1)
                }
                .frame(maxWidth: 176)
            }
            .buttonStyle(.locus())
            .help(model.modelSelectionLockReason ?? (agentTeams.teamModeEnabled
                ? "Active team: \(model.selectedTeamModelNames.joined(separator: ", "))"
                : "Select model"))
            .accessibilityLabel(model.modelSelectionLockReason != nil
                ? "Model locked, \(model.modelPickerLabel)"
                : agentTeams.teamModeEnabled
                ? "Active team, \(model.modelPickerLabel), \(runtimeHealthTitle)"
                : "Select model, \(model.modelPickerLabel), \(runtimeHealthTitle)")
            .accessibilityIdentifier("workspace.modelPicker")
            .frame(height: 28)
            .popover(isPresented: $modelPickerPresented, arrowEdge: .top) {
                ModelPickerPopover {
                    modelPickerPresented = false
                }
                .environmentObject(model)
            }

            WorkspaceActionsMenu()
                .environmentObject(model)

        }
        // When the sidebar is absent this column begins at the window edge.
        // Keep its restore control beyond the native traffic-light cluster.
        .padding(.leading, compactHeader ? 12 : sidebarVisible ? 20 : 76)
        .padding(.trailing, compactHeader ? 10 : 18)
        .frame(height: compactHeader ? 42 : WorkspaceLayoutMetrics.toolbarHeight)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
    }

    private var shouldShowWorkStatus: Bool {
        if model.isBusy || model.hasPendingPermission { return true }
        switch model.agentRuntimePhase {
        case .online: break
        case .starting, .recovering, .unavailable: return true
        }
        switch model.modelRuntimePhase {
        case .online: break
        case .starting, .recovering, .unavailable: return true
        }
        switch model.orchestrationState {
        case .queued, .dispatching, .running, .reviewing,
             .waitingPermission, .waitingComputer, .waitingDispatchApproval,
             .paused, .failed, .interrupted:
            return true
        case .completed, .cancelled, .discarded, nil:
            return false
        }
    }

    private var runtimeHealthColor: Color {
        let phase = model.isAgentOnline ? model.modelRuntimePhase : model.agentRuntimePhase
        return switch phase {
        case .online: viewColors.success
        case .starting, .recovering: viewColors.warning
        case .unavailable: viewColors.coral
        }
    }

    private var runtimeHealthTitle: String {
        let phase = model.isAgentOnline ? model.modelRuntimePhase : model.agentRuntimePhase
        return switch phase {
        case .online: "ready"
        case .starting: "starting"
        case .recovering: "recovering"
        case .unavailable: "unavailable"
        }
    }

    private var teamProgressTitle: String {
        if model.selectedTeamRouteIssue != nil { return "Needs setup" }
        return model.orchestrationState?.title ?? "Ready"
    }

    private var teamProgressColor: Color {
        if model.selectedTeamRouteIssue != nil { return viewColors.coral }
        switch model.orchestrationState {
        case .completed: return viewColors.success
        case .failed, .interrupted, .cancelled, .discarded: return viewColors.coral
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            return viewColors.warning
        case .queued, .dispatching, .running, .reviewing: return viewColors.signalDeep
        case nil: return viewColors.success
        }
    }

    private func runtimeBanner(_ message: String, recovering: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: recovering ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                .foregroundStyle(recovering ? viewColors.warning : viewColors.coral)
            Text(message)
                .font(.locus(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button("Settings") { model.presentSettings() }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .underline()
                .accessibilityIdentifier("banner.settings")
            Button("Retry") {
                model.retryLocalServices()
            }
            .font(.locus(size: 9, weight: .semibold))
            .accessibilityIdentifier("banner.retry")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background((recovering ? viewColors.warning : viewColors.coral).opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((recovering ? viewColors.warning : viewColors.coral).opacity(0.25))
                .frame(height: 1)
        }
    }
}

/// Moves the chat column aside while a docked request overview owns the
/// trailing side of the workspace, and back once the card minimizes or closes.
///
/// The column follows the resolved layout in its own transaction. A send
/// presents the overview in the same update that appends the user's row and
/// clears the draft, and a chat switch dismisses it while the transcript is
/// replaced; animating on the overview flags would spring those changes too.
/// Here only the column's exact width and alignment move. Reduce Motion, live
/// resizing and large transcripts take the resolved layout at once, matching
/// the root panel motion.
private struct ConversationColumnDocking: ViewModifier {
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locusIsLiveResizing) private var isLiveResizing
    let workspaceWidth: CGFloat
    let overview: RequestOverviewLayout
    @State private var settled: RequestOverviewLayout?

    private var immediate: Bool {
        reduceMotion || isLiveResizing || transcriptPresentation.snapshot.prefersImmediatePanelLayout
    }

    func body(content: Content) -> some View {
        let layout = immediate ? overview : (settled ?? overview)
        content
            .environment(\.locusConversationColumnAlignment, layout.docked ? .leading : .center)
            // Exact widths, never flexible ones: see RootView's note on
            // re-negotiating widths with a long native-text transcript.
            .frame(width: layout.conversationWidth(in: workspaceWidth))
            .frame(width: workspaceWidth, alignment: .leading)
            .onAppear { settled = overview }
            .onChange(of: overview) { _, next in
                withAnimation(immediate ? nil : LocusMotion.spatial) { settled = next }
            }
    }
}

private struct WorkspaceSessionTitle: View {
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    let sessionID: String

    var body: some View {
        Text(
            sessionCatalog.snapshot.sessionsByID[sessionID]?.displayTitle
                ?? (transcriptPresentation.snapshot.isEmpty ? "New session" : "Active session")
        )
        .font(.locus(size: 13, weight: .bold))
        .lineLimit(1)
        .accessibilityIdentifier("workspace.sessionTitle")
    }
}

/// Keeps workspace-profile publications scoped to the one header control that
/// needs them instead of invalidating the full conversation workspace.
private struct WorkspaceEffortPicker: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @State private var isPresented = false

    var body: some View {
        // Observe the catalog owner even when this control is initially empty.
        if !model.reasoningEffortOptions.isEmpty {
            picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        let effort = resolvedEffort
        let label = effort.isEmpty ? "Auto" : effort.capitalized
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(viewColors.muted)
                Text(label)
                    .font(.locus(size: 9, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(viewColors.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(viewColors.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(viewColors.line, lineWidth: 1)
            }
        }
        .buttonStyle(.locus())
        .help("Reasoning effort · \(label)")
        .accessibilityLabel("Reasoning effort, \(label)")
        .accessibilityIdentifier("workspace.effortPicker")
        .frame(height: 28)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            effortPopover(selectedEffort: effort)
        }
    }

    private var resolvedEffort: String {
        let path = SessionSummary.canonicalWorkspacePath(model.workspacePath)
        if let workspaceEffort = sessionCatalog.snapshot.workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path) == path
        })?.reasoningEffort {
            return workspaceEffort
        }
        return model.activeAccount?.codexReasoningEffortValue ?? ""
    }

    private func effortPopover(selectedEffort: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reasoning effort")
                .font(.locus(size: 10, weight: .bold))

            effortRow(effort: "", title: "Auto", selectedEffort: selectedEffort)
            ForEach(model.reasoningEffortOptions, id: \.self) { effort in
                effortRow(
                    effort: effort,
                    title: effort.capitalized,
                    selectedEffort: selectedEffort
                )
            }

            Divider().overlay(viewColors.line)

            Text(
                "Applies to this workspace and takes effect on the next message. "
                + "Higher efforts think longer and cost more."
            )
            .font(.locus(size: 8))
            .foregroundStyle(viewColors.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 240)
        .background(viewColors.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.effortPicker.popover")
    }

    private func effortRow(
        effort: String,
        title: String,
        selectedEffort: String
    ) -> some View {
        Button {
            model.setReasoningEffort(effort)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 12)
                if selectedEffort == effort {
                    Image(systemName: "checkmark")
                        .font(.locus(size: 8, weight: .bold))
                }
            }
            .font(.locus(size: 9, weight: .semibold))
            .foregroundStyle(viewColors.inkSoft)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(selectedEffort == effort ? viewColors.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityIdentifier("workspace.effortPicker.\(effort.isEmpty ? "auto" : effort)")
    }
}

/// Two fully addressable chat slots backed by the app's shared worker registry.
/// The focused slot owns the live runtime UI; the other remains readable and
/// editable from its cached transcript while its worker continues in the background.
enum ChatWorkspacePresentation: Equatable {
    case single
    case sideBySide

    static func resolve(isSplit: Bool) -> Self {
        isSplit ? .sideBySide : .single
    }
}

struct SplitChatWorkspaceView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locusWorkspaceGeometry) private var workspaceGeometry
    let sidebarVisible: Bool
    let showSidebar: () -> Void

    var body: some View {
        Group {
            switch ChatWorkspacePresentation.resolve(isSplit: model.splitViewActive && model.savedAgentOverviewProfile == nil) {
            case .single:
                liveWorkspace
            case .sideBySide:
                sideBySide(width: workspaceGeometry.workspaceWidth)
            }
        }
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: model.splitViewActive)
    }

    private var liveWorkspace: some View {
        WorkspaceView(sidebarVisible: sidebarVisible, showSidebar: showSidebar)
    }

    private func sideBySide(width: CGFloat) -> some View {
        let dividerWidth: CGFloat = 8
        let usable = max(0, width - dividerWidth)
        let minimumRatio = min(0.5, 360 / max(usable, 1))
        let ratio = min(
            max(CGFloat(model.chatSplitRestoration.dividerRatio), minimumRatio),
            1 - minimumRatio
        )
        return HStack(spacing: 0) {
            pane(.primary)
                .frame(width: usable * ratio)

            SplitPaneDivider(totalWidth: usable, minimumRatio: Double(minimumRatio))
                .environmentObject(model)
                .frame(width: dividerWidth)

            pane(.secondary)
                .frame(width: usable * (1 - ratio))
        }
    }

    @ViewBuilder
    private func pane(_ pane: ChatPaneID) -> some View {
        if model.chatSplitRestoration.focusedPane == pane {
            liveWorkspace
                .overlay(alignment: .leading) {
                    Rectangle().fill(viewColors.signalDeep).frame(width: 2)
                }
                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                    handlePaneDrop(providers, into: pane)
                }
                .accessibilityIdentifier("split.pane.\(pane.rawValue).focused")
        } else if let sessionID = model.splitSessionID(for: pane),
                  let session = sessionCatalog.snapshot.sessionsByID[sessionID]
        {
            BackgroundChatPane(
                pane: pane,
                session: session,
                paneState: model.chatPaneState(for: pane)
            )
                .environmentObject(model)
        } else {
            Color.clear
        }
    }

    private func handlePaneDrop(_ providers: [NSItemProvider], into pane: ChatPaneID) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let payload = value as? String,
                  payload.hasPrefix("locus-chat:"),
                  let sessionID = payload.split(separator: ":").last.map(String.init)
            else { return }
            Task { @MainActor in
                if let session = model.sessions.first(where: { $0.id == sessionID }) {
                    model.open(session, in: pane)
                }
            }
        }
        return true
    }
}

private struct SplitPaneDivider: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    let totalWidth: CGFloat
    let minimumRatio: Double
    @State private var startingRatio: Double?

    var body: some View {
        Rectangle()
            .fill(viewColors.line)
            .overlay { Capsule().fill(viewColors.muted.opacity(0.45)).frame(width: 2, height: 34) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = startingRatio ?? model.chatSplitRestoration.dividerRatio
                    if startingRatio == nil { startingRatio = start }
                    let proposed = start + Double(value.translation.width / max(totalWidth, 1))
                    model.setSplitDividerRatio(min(max(proposed, minimumRatio), 1 - minimumRatio))
                }
                .onEnded { _ in startingRatio = nil })
            .help("Resize chat panes")
            .accessibilityLabel("Chat pane divider")
            .accessibilityIdentifier("split.divider")
    }
}

private struct BackgroundChatPane: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pane: ChatPaneID
    let session: SessionSummary
    @ObservedObject var paneState: ChatPaneState

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .locusWorkspaceBackground()
        .contentShape(Rectangle())
        .onTapGesture { model.focusChatPane(pane) }
        .onAppear { model.refreshSplitPane(session.id) }
        .onDrop(of: [.plainText], isTargeted: nil, perform: handleDrop)
        .overlay {
            Rectangle().stroke(viewColors.line, lineWidth: 1)
        }
        .accessibilityIdentifier("split.pane.\(pane.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.locus(size: 13, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.chatHasActiveRun(session) ? viewColors.success : viewColors.muted.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(session.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? "Saved chat")
                        .lineLimit(1)
                }
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(viewColors.muted)
            }
            Spacer()
            Button {
                model.focusChatPane(pane)
            } label: {
                Label("Focus", systemImage: "cursorarrow.click")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.locus())
            .help("Focus this chat")
            .accessibilityIdentifier("split.pane.\(pane.rawValue).focus")
            Button {
                model.closeChatPane(pane)
            } label: {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.locus())
            .help("Close pane — running work continues")
            .accessibilityIdentifier("split.pane.\(pane.rawValue).close")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(viewColors.line).frame(height: 1) }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                let blocks = model.paneBlocks(for: session.id)
                if blocks.isEmpty {
                    ProgressView("Loading chat…")
                        .controlSize(.small)
                        .foregroundStyle(viewColors.muted)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(blocks) { block in
                        PassiveChatBlockView(
                            block: block,
                            accent: model.effectiveAccent,
                            workspacePath: session.cwd ?? model.workspacePath
                        )
                        .environment(\.responseOutputContext, model.responseOutputContext(sessionID: session.id))
                    }
                }
            }
            .frame(maxWidth: 780)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("\(session.displayTitle) transcript")
    }

    private var composer: some View {
        VStack(spacing: 7) {
            TextEditor(text: Binding(
                get: { paneState.draft },
                set: { model.setPaneDraft($0, for: session.id) }
            ))
            .foregroundStyle(viewColors.inkSoft)
            .tint(viewColors.accentAction)
            .font(.locus(size: 12))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 44, maxHeight: 92)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(viewColors.paperDeep.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("split.pane.\(pane.rawValue).composer")

            HStack {
                Text(model.chatHasActiveRun(session) ? "Working in background" : "Ready")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(viewColors.muted)
                Spacer()
                Button {
                    model.submitDraft(in: pane)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.locus(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(viewColors.ink)
                .disabled(paneState.draft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send in \(session.displayTitle)")
                .accessibilityIdentifier("split.pane.\(pane.rawValue).send")
            }
        }
        .padding(10)
        .locusWorkspaceBackground()
        .overlay(alignment: .top) { Rectangle().fill(viewColors.line).frame(height: 1) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let payload = value as? String,
                  payload.hasPrefix("locus-chat:"),
                  let sessionID = payload.split(separator: ":").last.map(String.init)
            else { return }
            Task { @MainActor in
                if let dropped = model.sessions.first(where: { $0.id == sessionID }) {
                    withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                        model.open(dropped, in: pane)
                    }
                }
            }
        }
        return true
    }
}

private struct PassiveChatBlockView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let block: ChatBlock
    let accent: LocusAccentSelection
    let workspacePath: String

    var body: some View {
        switch block.kind {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(block.text)
                    .font(.locus(size: 11))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(viewColors.paperDeep.opacity(0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 9) {
                LocusMessageMarker(accent: accent)
                Group {
                    if !block.isStreaming, let document = block.responseParts, document.isSupported {
                        ResponsePartsView(document: document, block: block, workspacePath: workspacePath)
                    } else {
                MessageContentView(
                    text: block.text,
                    isStreaming: block.isStreaming,
                    reasoningText: block.reasoningText,
                    reasoningSections: block.reasoningSections,
                    reasoningFormat: block.reasoningFormat ?? .legacyTags,
                    workspacePath: workspacePath,
                    thinkingVisibility: .collapsed
                )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            Label(block.tool?.summary ?? "Tool activity", systemImage: "wrench.and.screwdriver")
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(viewColors.muted)
                .padding(9)
                .background(viewColors.paperDeep.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .note:
            Text(block.text)
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(viewColors.muted)
        case .error:
            Label(block.text, systemImage: "xmark.octagon.fill")
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(viewColors.coral)
        }
    }
}

struct ReviewAndLandView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination = "local"
    @State private var branchName = ""
    @State private var commitMessage = ""
    @State private var commandsText = ""
    @State private var confirmOverride = false

    private var commands: [String] {
        Array(commandsText.split(separator: "\n", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.prefix(8))
    }

    private var checksAreCurrentAndPassing: Bool {
        guard let check = landingFlow.landingCheckRun, let preflight = landingFlow.landingPreflight else {
            return false
        }
        return check.passed && check.tree == preflight.tree
    }

    private var branchProblem: String? {
        destination == "branch" ? GitBranchName.validationError(branchName) : nil
    }

    private var canLand: Bool {
        guard let preflight = landingFlow.landingPreflight, preflight.patchBytes > 0,
              !landingFlow.isLandingOperationRunning else { return false }
        if destination == "local" { return preflight.canApplyLocal }
        return branchProblem == nil
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review & Land")
                        .font(.locus(size: 17, weight: .bold))
                    Text("Review the complete worktree delta, verify it, then choose its destination.")
                        .font(.locus(size: 10))
                        .foregroundStyle(viewColors.muted)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        stageHeader("1", "Review changes")
                        if let preflight = landingFlow.landingPreflight {
                            HStack {
                                Text("\(preflight.paths.count) file\(preflight.paths.count == 1 ? "" : "s")")
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(preflight.patchBytes), countStyle: .file
                                ))
                                Spacer()
                                Button("Copy Patch") { model.copyActiveTaskPatch() }
                                Button("Open Checkout") { model.openActiveTaskCheckout() }
                            }
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(viewColors.muted)

                            ScrollView([.horizontal, .vertical]) {
                                Text(landingFlow.landingPatch.isEmpty ? "No changes." : landingFlow.landingPatch)
                                    .font(.locus(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 210)
                            .background(viewColors.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(viewColors.line) }
                            .accessibilityIdentifier("landing.diff")
                        }

                        Divider()
                        stageHeader("2", "Review test evidence")
                        Text("Enter one explicit check per line. Locus runs up to eight sequentially in this chat’s worktree; each has a ten-minute limit.")
                            .font(.locus(size: 9))
                            .foregroundStyle(viewColors.muted)
                        TextEditor(text: $commandsText)
                            .foregroundStyle(viewColors.inkSoft)
                            .tint(viewColors.accentAction)
                            .font(.locus(size: 10, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 78)
                            .background(viewColors.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(viewColors.line) }
                            .accessibilityIdentifier("landing.checkCommands")
                        HStack {
                            if landingFlow.activeLandingCheckRunID != nil {
                                ProgressView().controlSize(.small)
                                Text("Running checks…")
                                    .font(.locus(size: 9))
                                Button("Stop") { landingFlow.stopLandingChecks() }
                                    .accessibilityIdentifier("landing.stopChecks")
                            } else {
                                Button("Run Checks") { landingFlow.runLandingChecks(commands: commands) }
                                    .disabled(commands.isEmpty || landingFlow.isLandingOperationRunning)
                                    .accessibilityIdentifier("landing.runChecks")
                            }
                            Spacer()
                            if checksAreCurrentAndPassing {
                                Label("Checks passed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(viewColors.success)
                            } else if let check = landingFlow.landingCheckRun {
                                Label(
                                    check.tree == landingFlow.landingPreflight?.tree
                                        ? "Checks did not pass" : "Checks are stale",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(viewColors.warning)
                            } else {
                                Text("No current check evidence")
                                    .foregroundStyle(viewColors.muted)
                            }
                        }
                        .font(.locus(size: 9, weight: .semibold))

                        if let run = landingFlow.landingCheckRun {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(run.results) { result in
                                    DisclosureGroup {
                                        if !result.output.isEmpty {
                                            Text(result.output)
                                                .font(.locus(size: 8, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: result.state == "passed"
                                                ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            Text(result.command).lineLimit(1)
                                            Spacer()
                                            Text(result.state.replacingOccurrences(of: "_", with: " "))
                                            Text("\(result.durationMilliseconds) ms")
                                        }
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(result.state == "passed"
                                            ? viewColors.success : viewColors.warning)
                                    }
                                }
                            }
                            .padding(10)
                            .background(viewColors.white.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Divider()
                        stageHeader("3", "Choose destination")
                        landingDestinationControl

                        if destination == "local" {
                            if landingFlow.landingPreflight?.canApplyLocal == true {
                                Text("The complete patch will be applied unstaged to Local. This chat remains in its worktree.")
                                    .font(.locus(size: 9))
                                    .foregroundStyle(viewColors.muted)
                            } else {
                                Label(
                                    landingFlow.landingPreflight?.conflict.nilIfEmpty
                                        ?? "The patch conflicts with Local. Both checkouts are unchanged.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.locus(size: 9))
                                .foregroundStyle(viewColors.coral)
                            }
                        } else if let task = model.activeTaskRecord, task.landingCommit != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Committed on \(task.branch ?? branchName)", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(viewColors.success)
                                HStack {
                                    Button("Publish") { model.publishLandedWorktree() }
                                        .disabled(landingFlow.isLandingOperationRunning)
                                    Button("Open Pull Request") { model.openLandedPullRequest() }
                                    Text(task.landingCommit?.prefix(10) ?? "")
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(viewColors.muted)
                                }
                            }
                        } else {
                            TextField("Branch name", text: $branchName)
                                .accessibilityIdentifier("landing.branch")
                            if let branchProblem {
                                Text(branchProblem).font(.locus(size: 8)).foregroundStyle(viewColors.coral)
                            }
                            TextField("Commit message", text: $commitMessage, axis: .vertical)
                                .lineLimit(2...5)
                                .accessibilityIdentifier("landing.commitMessage")
                            Text("A failed commit hook leaves the new branch and staged index ready to inspect and retry.")
                                .font(.locus(size: 8))
                                .foregroundStyle(viewColors.muted)
                        }
                        Color.clear
                            .frame(height: 0)
                            .id("landing.destination.bottom")
                            .accessibilityHidden(true)
                    }
                    .padding(18)
                }
                .onChange(of: destination) { _, destination in
                    guard destination == "branch" else { return }
                    proxy.scrollTo("landing.destination.bottom", anchor: .bottom)
                }
            }

            Divider()
            HStack {
                Text(checksAreCurrentAndPassing
                    ? "Current checks passed."
                    : "Landing without passing current checks requires an explicit confirmation.")
                    .font(.locus(size: 9))
                    .foregroundStyle(checksAreCurrentAndPassing ? viewColors.success : viewColors.warning)
                Spacer()
                if model.activeTaskRecord?.landingCommit != nil && destination == "branch" {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(checksAreCurrentAndPassing ? "Land Changes" : "Land Anyway…") {
                        if checksAreCurrentAndPassing { land(override: false) }
                        else { confirmOverride = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canLand)
                    .accessibilityIdentifier("landing.confirm")
                }
            }
            .padding(14)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 650, idealHeight: 760)
        .locusWorkspaceBackground()
        .onAppear {
            commandsText = model.currentLandingCheckCommands.joined(separator: "\n")
            if let existing = model.activeTaskRecord?.branch { branchName = existing }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await landingFlow.refreshLandingReview()
            }
        }
        .alert("Land without passing current checks?", isPresented: $confirmOverride) {
            Button("Cancel", role: .cancel) {}
            Button("Land Anyway", role: .destructive) { land(override: true) }
                .accessibilityIdentifier("landing.overrideConfirm")
        } message: {
            Text("This confirmation is recorded in the run timeline. Review failures or stale evidence before continuing.")
        }
    }

    private var landingDestinationControl: some View {
        HStack(spacing: 2) {
            landingDestinationButton("Apply to Local", value: "local")
            landingDestinationButton("Branch, Commit & PR", value: "branch")
        }
        .padding(2)
        .background(viewColors.paperDeep)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(viewColors.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
        .accessibilityIdentifier("landing.destination")
    }

    private func landingDestinationButton(_ title: String, value: String) -> some View {
        let selected = destination == value
        return Button {
            destination = value
        } label: {
            Text(title)
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(selected ? viewColors.ink : viewColors.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? viewColors.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func stageHeader(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.locus(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(viewColors.brandInk)
                .frame(width: 22, height: 22)
                .background(viewColors.signal)
                .clipShape(Circle())
            Text(title).font(.locus(size: 12, weight: .bold))
        }
    }

    private func land(override: Bool) {
        landingFlow.landActiveTask(
            destination: destination,
            branch: branchName,
            commitMessage: commitMessage,
            overrideFailedChecks: override
        )
    }
}

private enum ActivityGroup: String, CaseIterable, Identifiable {
    case attention = "Needs Attention"
    case running = "Running"
    case queued = "Queued"
    case recent = "Finished"

    var id: String { rawValue }
}

/// Activity rows use restrained text actions, but each still needs a reliable
/// macOS click target. Padding lives inside the button style so the visible and
/// accessibility frames agree instead of exposing a ten-point-tall link.
struct ActivityActionButtonStyle: ButtonStyle {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .frame(minHeight: 22)
            .background(configuration.isPressed ? viewColors.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ActivityCenterView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @State private var workflowRetryConfirmation: AttentionItem?
    @State private var clearUnavailableConfirmationPresented = false
    @State private var filter = ActivityFilter()
    @State private var selectedResultID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 4) {
                activityTab(.inbox, count: activityCenter.displayedAttentionItems.count + activityCenter.attentionRuns.count)
                activityTab(.inProgress, count: activityCenter.inProgressRuns.count)
                activityTab(.completed, count: activityCenter.completedRuns.count)
            }
            .padding(4)
            .background(viewColors.paperDeep.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("activity.tabSwitcher")
            filters
            Divider().overlay(viewColors.line)
            if activityCenter.selectedTab == .completed {
                completedInbox
            } else if filteredRuns.isEmpty && filteredAttentionItems.isEmpty {
                emptyContent
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if activityCenter.selectedTab == .inbox { attentionSections }
                            ForEach(ActivityGroup.allCases) { group in
                                let values = runs(in: group)
                                if !values.isEmpty {
                                    sectionHeading(group.rawValue, count: values.count)
                                    ForEach(values) { run in activityRow(run, now: context.date) }
                                }
                            }
                        }.padding(20)
                    }
                }
            }
        }
        .foregroundStyle(viewColors.ink)
        .background(viewColors.paper)
        .onExitCommand {
            if selectedResultID != nil { selectedResultID = nil }
            else { activityCenter.activityCenterPresented = false }
        }
        .onChange(of: filter) { _, _ in selectedResultID = nil }
        .onChange(of: activityCenter.focus) { _, _ in selectedResultID = nil }
        .task {
            while !Task.isCancelled {
                await activityCenter.refreshActivityRuns(announceFailure: false)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Retry this workflow step?",
            isPresented: Binding(
                get: { workflowRetryConfirmation != nil },
                set: { if !$0 { workflowRetryConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = workflowRetryConfirmation {
                Button("Retry Step") {
                    workflowRetryConfirmation = nil
                    model.performAttentionAction(item, action: "retry")
                }
            }
            Button("Cancel", role: .cancel) { workflowRetryConfirmation = nil }
        } message: {
            Text(
                "Connector actions already recorded will not repeat. Files or commands from "
                + "the failed attempt may still be present in the workspace."
            )
        }
        .confirmationDialog(
            "Clear \(unavailableAttentionItems.count) unavailable recoveries?",
            isPresented: $clearUnavailableConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Unavailable", role: .destructive) {
                model.clearUnavailableAttentionRecoveries()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "They will leave Attention because their original chats no longer exist. "
                + "Their discarded run history will remain in the Activity Center."
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.center")
    }

    private var unavailableAttentionItems: [AttentionItem] {
        activityCenter.attentionItems.filter {
            $0.kind == "recoverable_run" && $0.unavailable == true
        }
    }

    private func activityTab(_ tab: ActivityCenterModel.Tab, count: Int) -> some View {
        Button {
            activityCenter.selectTab(tab)
        } label: {
            HStack(spacing: 5) {
                Text(tab.rawValue)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(activityCenter.selectedTab == tab ? viewColors.ink : viewColors.muted)
                }
            }
            .font(.locus(size: 12, weight: activityCenter.selectedTab == tab ? .semibold : .medium))
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(activityCenter.selectedTab == tab ? viewColors.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus(.quiet))
        .accessibilityLabel(tab.rawValue)
        .accessibilityValue("\(count) items, \(activityCenter.selectedTab == tab ? "selected" : "not selected")")
        .accessibilityAddTraits(activityCenter.selectedTab == tab ? [.isSelected] : [])
        .accessibilityIdentifier("activity.tab.\(tab == .inbox ? "inbox" : tab == .inProgress ? "inProgress" : "completed")")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.system(size: 22, weight: .medium))
                .foregroundStyle(viewColors.signalDeep)
                .frame(width: 42, height: 42)
                .background(viewColors.paperDeep, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity Center").font(.locus(size: 20, weight: .bold))
                Text("Your agents’ work, in one place.").font(.locus(size: 12)).foregroundStyle(viewColors.muted)
            }
            Spacer(minLength: 0)
            if activityCenter.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await activityCenter.refreshActivityRuns() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 30, height: 30)
            }
            .disabled(activityCenter.isRefreshing).help("Refresh activity")
            .accessibilityLabel("Refresh activity").accessibilityIdentifier("activity.refresh")
            Button { activityCenter.activityCenterPresented = false } label: {
                Image(systemName: "xmark").frame(width: 30, height: 30)
            }
            .help("Close Activity Center").accessibilityLabel("Close Activity Center")
            .accessibilityIdentifier("activity.close")
        }.buttonStyle(.locus()).padding(20)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let focus = activityCenter.focus {
                HStack {
                    Text(focusLabel(focus))
                    Spacer()
                    Button("Show all") { activityCenter.clearFocus() }
                        .accessibilityIdentifier("activity.showAll")
                }.font(.locus(size: 12)).accessibilityIdentifier("activity.focus")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(viewColors.muted)
                TextField("Search tasks, agents, or workspaces", text: $filter.search)
                    .textFieldStyle(.plain).accessibilityIdentifier("activity.search")
                if !filter.search.isEmpty {
                    Button { filter.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .font(.locus(size: 12)).padding(10)
            .background(viewColors.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(viewColors.line) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { filterPickers; resetFilters }
                VStack(alignment: .leading, spacing: 8) { filterPickers; resetFilters }
            }
            if let error = activityCenter.focusError ?? activityCenter.refreshError {
                Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.locus(size: 11)).foregroundStyle(viewColors.warning)
            }
            if activityCenter.selectedTab == .inbox, !unavailableAttentionItems.isEmpty {
                Button("Clear unavailable recoveries") { clearUnavailableConfirmationPresented = true }
                    .disabled(model.isClearingUnavailableAttention)
                    .buttonStyle(ActivityActionButtonStyle())
                    .accessibilityIdentifier("attention.clearUnavailable")
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var filterPickers: some View {
        Picker("Agent", selection: $filter.agentID) {
            Text("All agents").tag("")
            ForEach(agentOptions, id: \.id) { Text($0.name).tag($0.id) }
        }.accessibilityIdentifier("activity.filter.agent")
        Picker("Time", selection: $filter.time) {
            ForEach(ActivityFilter.TimeRange.allCases) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("activity.filter.time")
        Picker("Type", selection: $filter.kind) {
            ForEach(ActivityFilter.Kind.allCases) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("activity.filter.type")
    }

    private var resetFilters: some View {
        Button("Reset filters") { filter = ActivityFilter() }
            .disabled(!filter.isActive && filter.readState == .all)
            .buttonStyle(ActivityActionButtonStyle()).fixedSize()
            .accessibilityIdentifier("activity.filter.reset")
    }

    private var agentOptions: [(id: String, name: String)] {
        var options: [String: String] = [:]
        for run in activityCenter.displayedActivityRuns {
            options[agentKey(for: run)] = agentName(for: run) ?? "Unassigned"
        }
        for item in activityCenter.displayedAttentionItems {
            let run = relatedRun(item)
            let session = item.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0] }
            let key = ActivityFilter.agentKey(run: run, session: session)
            let name = run.flatMap { agentName(for: $0) } ?? session?.savedAgentProfileID.flatMap { id in
                agentTeams.agentProfiles.first { $0.id == id }?.name
            } ?? session?.agentName ?? "Unassigned"
            options[key] = name
        }
        return options.map { (id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func relatedRun(_ item: AttentionItem) -> OrchestrationRun? {
        activityCenter.displayedActivityRuns.first { $0.id == item.runID }
    }
    private func agentKey(for run: OrchestrationRun) -> String {
        ActivityFilter.agentKey(run: run, session: run.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0] })
    }

    private var filteredAttentionItems: [AttentionItem] {
        guard activityCenter.selectedTab == .inbox else { return [] }
        return activityCenter.displayedAttentionItems.filter { item in
            let run = relatedRun(item)
            let session = item.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0] }
            let key = ActivityFilter.agentKey(run: run, session: session)
            return filter.matches(agentID: key, timestamp: item.timestamp,
                kind: .kind(for: item, run: run), text: [item.title, item.detail, session?.displayTitle ?? "",
                    agentOptions.first { $0.id == key }?.name ?? ""])
        }
    }

    private var filteredRuns: [OrchestrationRun] {
        let values: [OrchestrationRun]
        switch activityCenter.selectedTab {
        case .inbox: values = activityCenter.attentionRuns
        case .inProgress: values = activityCenter.inProgressRuns
        case .completed: values = activityCenter.completedRuns
        }
        return values.filter { run in
            let matchesRead = activityCenter.selectedTab != .completed || filter.readState == .all
                || (filter.readState == .unread) == activityCenter.activityIsUnseen(run)
            return matchesRead && filter.matches(agentID: agentKey(for: run),
                timestamp: run.completedAt ?? run.updatedAt, kind: .kind(for: run),
                text: [chatTitle(for: run), taskTitle(run), workspaceTitle(for: run), agentName(for: run) ?? "", run.request, statusTitle(for: run)])
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 12) {
            if activityCenter.isRefreshing && !activityCenter.hasLoadedActivity && activityCenter.activityRuns.isEmpty {
                ProgressView("Loading activity…")
            } else if activityCenter.refreshError != nil && !activityCenter.hasLoadedActivity && activityCenter.activityRuns.isEmpty {
                ContentUnavailableView("Activity unavailable", systemImage: "wifi.exclamationmark",
                    description: Text("Refresh to try loading your tasks again."))
            } else if filter.isActive || (activityCenter.selectedTab == .completed && filter.readState != .all) {
                ContentUnavailableView("No matching activity", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try a different search or reset your filters."))
                Button("Reset filters") { filter = ActivityFilter() }
            } else {
                ContentUnavailableView(
                    activityCenter.selectedTab == .inbox ? "You’re all caught up"
                        : activityCenter.selectedTab == .inProgress ? "Nothing in progress" : "No completed tasks yet",
                    systemImage: activityCenter.selectedTab == .inbox ? "checkmark.circle" : "tray",
                    description: Text(activityCenter.selectedTab == .inbox ? "Requests and work that needs attention appear here."
                        : activityCenter.selectedTab == .inProgress ? "Tasks appear here when they start or join the queue."
                        : "Finished work will arrive here, ready to read."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("activity.empty")
    }

    private func taskTitle(_ run: OrchestrationRun) -> String {
        let text = ChatTranscriptBuilder.displayUserText(run.request).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((text.split(separator: "\n").first.map(String.init) ?? "").prefix(180)).nilIfEmpty ?? chatTitle(for: run)
    }

    private var selectedResult: OrchestrationRun? {
        // Keep the open message visible when reading it removes its unread row.
        activityCenter.completedRuns.first { $0.id == selectedResultID }
    }

    private var completedInbox: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 760 || selectedResult == nil {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Picker("Show", selection: $filter.readState) {
                                ForEach(ActivityFilter.ReadState.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().accessibilityLabel("Result read status")
                                .accessibilityIdentifier("activity.filter.read")
                            Spacer(minLength: 0)
                            Menu {
                                Button("Mark shown as read") { activityCenter.markAllActivitySeen(matching: Set(filteredRuns.map(\.id))) }
                                    .accessibilityIdentifier("activity.markAllSeen")
                                Button("Clear read results") { activityCenter.clearReadActivityRuns(matching: Set(filteredRuns.map(\.id))) }
                                    .accessibilityIdentifier("activity.clearRead")
                            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Inbox actions").accessibilityIdentifier("activity.inboxActions")
                        }.padding(12)
                        Divider().overlay(viewColors.line)
                        if filteredRuns.isEmpty { emptyContent }
                        else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredRuns) { run in resultRow(run) }
                                }
                            }.accessibilityIdentifier("activity.resultList")
                        }
                    }
                    .frame(width: geometry.size.width >= 760 ? min(360, geometry.size.width * 0.35) : nil)
                }
                if geometry.size.width >= 760 { Divider().overlay(viewColors.line) }
                if let run = selectedResult {
                    ActivityResultReader(run: run, title: taskTitle(run), agentName: agentName(for: run) ?? "Unassigned",
                        onBack: { selectedResultID = nil })
                        .id(run.id)
                } else if geometry.size.width >= 760 {
                    ContentUnavailableView("Select a completed task", systemImage: "envelope.open",
                        description: Text("Read its final answer and open its saved outputs here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func resultRow(_ run: OrchestrationRun) -> some View {
        let unread = activityCenter.activityIsUnseen(run)
        let selected = selectedResultID == run.id
        return Button { selectedResultID = run.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(unread ? viewColors.accentAction : .clear).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(agentName(for: run) ?? "Unassigned").font(.locus(size: 12, weight: unread ? .bold : .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Date(timeIntervalSince1970: run.completedAt ?? run.updatedAt), format: .dateTime.month(.abbreviated).day())
                            .font(.locus(size: 10)).foregroundStyle(viewColors.muted)
                    }
                    Text(taskTitle(run)).font(.locus(size: 13, weight: unread ? .semibold : .regular)).lineLimit(2)
                    Text("\(ActivityFilter.Kind.kind(for: run).rawValue) · \(workspaceTitle(for: run))")
                        .font(.locus(size: 11)).foregroundStyle(viewColors.muted).lineLimit(1)
                }
            }
            .foregroundStyle(viewColors.ink).multilineTextAlignment(.leading)
            .padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(selected ? viewColors.accentAction.opacity(0.12) : viewColors.white.opacity(unread ? 0.65 : 0.2))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { viewColors.line.frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(unread ? "Unread, " : "")\(taskTitle(run)), by \(agentName(for: run) ?? "Unassigned")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("activity.open.\(run.id)")
        .contextMenu {
            Button(unread ? "Mark as read" : "Mark unread") {
                if unread { activityCenter.markActivitySeen(run) } else { activityCenter.markActivityUnread(run) }
            }
            Button("Clear from Activity Center") { activityCenter.dismissActivityRun(run) }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.locus(size: 11, weight: .semibold))
            Text("\(count)").font(.locus(size: 10)).foregroundStyle(viewColors.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var attentionSections: some View {
        ForEach(AttentionGroup.allCases) { group in
            let items = filteredAttentionItems.filter { $0.group == group }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading(group == .decisions ? "Needs your decision" : group == .recoveries ? "Needs recovery" : "Check configuration", count: items.count)
                    ForEach(items) { attentionRow($0) }
                }
            }
        }
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: attentionSymbol(item))
                    .font(.locus(size: 13, weight: .semibold))
                    .foregroundStyle(item.group == .decisions
                        ? viewColors.warning : viewColors.signalDeep)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0]?.displayTitle } ?? item.title)
                        .font(.locus(size: 13, weight: .semibold))
                    Text(item.detail)
                        .font(.locus(size: 11))
                        .foregroundStyle(viewColors.inkSoft)
                        .textSelection(.enabled)
                    if let sessionID = item.sessionID,
                       sessionCatalog.snapshot.sessionsByID[sessionID] != nil {
                        Text(item.title)
                            .font(.locus(size: 10))
                            .foregroundStyle(viewColors.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let run = relatedRun(item), let name = agentName(for: run) {
                    Label(name, systemImage: "person.crop.circle")
                }
                Text(Date(timeIntervalSince1970: item.timestamp), format: .relative(presentation: .named))
            }.font(.locus(size: 11)).foregroundStyle(viewColors.muted)

            if item.kind == "structured_question",
               let request = model.blockingQuestion(for: item) {
                BlockingQuestionPromptView(
                    request: request,
                    onResolve: { answers, action in
                        model.resolveAttentionQuestion(item, answers: answers, action: action)
                    }
                )
            } else if item.kind == "completed_question",
                      let question = model.completedQuestion(for: item) {
                QuestionPromptView(
                    question: question,
                    onResolve: { option, text in
                        model.resolveAttentionCompletedQuestion(
                            item, option: option, freeText: text
                        )
                    },
                    onDismiss: { _ in }
                )
            } else {
                attentionActions(item)
            }
        }
        .padding(12)
        .background(viewColors.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(viewColors.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.item.\(item.id)")
    }

    @ViewBuilder
    private func attentionActions(_ item: AttentionItem) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(item.actions, id: \.self) { action in
                if action != "answer" {
                    if ["reject", "deny", "cancel", "clear"].contains(action) {
                        Button(attentionActionTitle(action), role: .destructive) {
                            model.performAttentionAction(item, action: action)
                        }
                    } else {
                        Button(attentionActionTitle(action)) {
                            if action == "retry", item.kind == "workflow_failure" {
                                workflowRetryConfirmation = item
                            } else {
                                model.performAttentionAction(item, action: action)
                            }
                        }
                    }
                }
            }
        }
        .font(.locus(size: 10, weight: .medium))
        .buttonStyle(ActivityActionButtonStyle())
    }

    private func attentionActionTitle(_ action: String) -> String {
        switch action {
        case "approve": "Approve"
        case "reject": "Reject"
        case "retry": "Retry"
        case "resume": "Resume"
        case "cancel": "Cancel"
        case "allow_once": "Allow Once"
        case "always_allow": "Always Allow"
        case "deny": "Deny"
        case "clear": "Clear"
        case "clear_warning": "Clear Warning"
        case "open_configuration": "Open Configuration"
        case "open_chat": "Open Chat"
        default: action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func attentionSymbol(_ item: AttentionItem) -> String {
        switch item.kind {
        case "workflow_approval": "hand.raised.fill"
        case "permission_request": "lock.shield.fill"
        case "structured_question", "completed_question": "questionmark.circle.fill"
        case "computer_control": "macwindow"
        case "team_plan": "person.3.sequence.fill"
        case "schedule_warning", "event_warning": "gearshape.fill"
        default: "arrow.clockwise.circle.fill"
        }
    }

    private func runs(in group: ActivityGroup) -> [OrchestrationRun] {
        let values = filteredRuns.filter { activityGroup(for: $0) == group }
        if group == .queued {
            return values.sorted {
                ($0.queuePosition ?? .max, $0.createdAt)
                    < ($1.queuePosition ?? .max, $1.createdAt)
            }
        }
        return values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func focusLabel(_ focus: ActivityCenterModel.Focus) -> String {
        switch focus {
        case .run: "Showing the selected run"
        case .workflow: "Showing the selected workflow"
        }
    }

    private func activityGroup(for run: OrchestrationRun) -> ActivityGroup {
        if activityCenter.isFinished(run) { return .recent }
        return switch run.state {
        case "waiting_permission", "waiting_computer", "waiting_dispatch_approval",
             "paused", "interrupted", "failed":
            .attention
        case "running", "dispatching", "reviewing":
            .running
        case "queued":
            .queued
        default:
            .recent
        }
    }

    private func activityRow(_ run: OrchestrationRun, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.openActivityRun(run) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: run))
                        .font(.locus(size: 15, weight: .semibold))
                        .foregroundStyle(color(for: run))
                        .frame(width: 22, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(chatTitle(for: run))
                            .font(.locus(size: 13, weight: .semibold))
                            .foregroundStyle(viewColors.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(statusTitle(for: run)).foregroundStyle(color(for: run))
                            Text("·")
                            Text(Date(timeIntervalSince1970: run.updatedAt), format: .relative(presentation: .named))
                        }
                        .font(.locus(size: 10))
                        .foregroundStyle(viewColors.muted)
                        .lineLimit(1)
                        if let name = agentName(for: run) {
                            Label("By \(name)", systemImage: run.runKind == "team" ? "person.3" : "person.crop.square")
                                .font(.locus(size: 10, weight: .medium))
                                .foregroundStyle(viewColors.inkSoft)
                                .lineLimit(1)
                                .help(name)
                                .accessibilityIdentifier("activity.agent.\(run.id)")
                        }
                        Text(workspaceTitle(for: run))
                            .font(.locus(size: 10))
                            .foregroundStyle(viewColors.muted)
                            .lineLimit(1)
                        if run.state != "completed" {
                            Text(run.recoveryReason?.nilIfEmpty ?? meaningfulStatus(for: run))
                                .font(.locus(size: 11))
                                .foregroundStyle(viewColors.inkSoft)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if activityCenter.isFinished(run), activityCenter.activityIsUnseen(run) {
                        Circle().fill(viewColors.accentAction).frame(width: 7, height: 7)
                            .padding(.top, 8)
                            .accessibilityLabel("Unread")
                    }
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus(.card))
            .help(activityCenter.isFinished(run) ? "Open task and mark as read" : "Open task")
            .accessibilityIdentifier("activity.open.\(run.id)")

            HStack(spacing: 8) {
                Button(run.state == "completed" ? "View result" : "Open chat") { model.openActivityRun(run) }
                    .foregroundStyle(viewColors.accentAction)
                if activityCenter.isFinished(run) {
                    if activityCenter.activityIsUnseen(run) {
                        Button("Mark as read") { activityCenter.markActivitySeen(run) }
                            .accessibilityIdentifier("activity.markRead.\(run.id)")
                    } else {
                        Button("Mark unread") { activityCenter.markActivityUnread(run) }
                            .accessibilityIdentifier("activity.markUnread.\(run.id)")
                    }
                } else if ["running", "dispatching", "reviewing"].contains(run.state) {
                    Button("Stop", role: .destructive) { model.stopActivityRun(run) }
                } else if run.state == "paused", run.runKind == "team" {
                    Button("Resume") { model.resumeOrchestration(run) }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("View timeline") {
                        model.openActivityRun(run)
                        model.selectInspectorTab(.runs)
                    }
                    if run.state == "queued" {
                        Button("Move to top") { model.updateQueuedRun(run, action: "move_top") }
                        Button("Move up") { model.updateQueuedRun(run, action: "move_up") }
                        Button("Move down") { model.updateQueuedRun(run, action: "move_down") }
                        Button("Cancel queued task", role: .destructive) { model.updateQueuedRun(run, action: "cancel") }
                    }
                    if ["running", "dispatching", "reviewing"].contains(run.state), run.runKind == "team" {
                        Button("Pause") { model.pauseOrchestration(run.id) }
                    }
                    if ["paused", "interrupted"].contains(run.state), run.runKind == "team" {
                        Button("Resume") { model.resumeOrchestration(run) }
                    } else if ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
                        Button(model.retryingRunIDs.contains(run.id) ? "Retrying…" : "Retry") { model.retryRun(run) }
                            .disabled(model.retryingRunIDs.contains(run.id))
                    }
                    if activityCenter.isFinished(run) {
                        Divider()
                        Button("Clear from Activity Center") {
                            activityCenter.dismissActivityRun(run)
                        }
                        .help("Remove this update. The chat and task stay saved.")
                        .accessibilityIdentifier("activity.clear.\(run.id)")
                    }
                    Divider()
                    Text("Duration: \(elapsed(run, now: now))")
                    Text(run.executionEnvironment == "worktree" ? "Runs in a worktree" : "Runs locally")
                    if let position = run.queuePosition { Text("Queue position: \(position)") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More task actions and details")
                .accessibilityLabel("More actions for \(chatTitle(for: run))")
                .accessibilityIdentifier("activity.more.\(run.id)")
            }
            .font(.locus(size: 10, weight: .medium))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(12)
        .background(viewColors.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(viewColors.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.run.\(run.id)")
    }

    private func statusTitle(for run: OrchestrationRun) -> String {
        switch run.state {
        case "completed": "Completed"
        case "cancelled", "discarded": "Stopped"
        case "waiting_permission": "Needs permission"
        case "waiting_computer": "Needs computer control"
        case "waiting_dispatch_approval": "Needs plan approval"
        default: TeamRunState(rawValue: run.state)?.title ?? "Updating"
        }
    }

    private func chatTitle(for run: OrchestrationRun) -> String {
        guard let sessionID = run.sessionID else { return "Unknown chat" }
        return sessionCatalog.snapshot.sessionsByID[sessionID]?.displayTitle ?? "Saved chat"
    }

    private func workspaceTitle(for run: OrchestrationRun) -> String {
        guard let path = run.workspaceRoot, !path.isEmpty else { return "Unknown workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func agentName(for run: OrchestrationRun) -> String? {
        ActivityCenterModel.agentName(
            for: run,
            session: run.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0] },
            profiles: agentTeams.agentProfiles
        )
    }

    private func elapsed(_ run: OrchestrationRun, now: Date) -> String {
        let end = run.completedAt.map(Date.init(timeIntervalSince1970:)) ?? now
        let seconds = max(Int(end.timeIntervalSince1970 - run.createdAt), 0)
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func meaningfulStatus(for run: OrchestrationRun) -> String {
        switch run.state {
        case "queued": "Waiting for a slot to start"
        case "waiting_permission": "Review this task’s permission request in your Inbox"
        case "waiting_computer": "Open the chat to continue with computer control"
        case "waiting_dispatch_approval": "The team plan is ready for review"
        case "paused": "Paused and ready to resume"
        case "interrupted": "Work stopped unexpectedly. Open the chat to review or resume"
        case "failed": "This task couldn’t finish. Open the chat to see what happened"
        case "completed": "Completed successfully"
        case "cancelled": "Stopped"
        case "dispatching": "Preparing to start…"
        case "reviewing": "Checking the result…"
        default: "Working on your task…"
        }
    }

    private func symbol(for run: OrchestrationRun) -> String {
        if ["failed", "interrupted"].contains(run.state) { return "exclamationmark.triangle.fill" }
        return switch activityGroup(for: run) {
        case .attention: "exclamationmark.triangle.fill"
        case .running: "waveform.path.ecg"
        case .queued: "clock.fill"
        case .recent: run.state == "completed" ? "checkmark.circle.fill" : "circle.fill"
        }
    }

    private func color(for run: OrchestrationRun) -> Color {
        if ["failed", "interrupted"].contains(run.state) { return viewColors.warning }
        return switch activityGroup(for: run) {
        case .attention: viewColors.warning
        case .running: viewColors.signalDeep
        case .queued: viewColors.blue
        case .recent: run.state == "completed" ? viewColors.success : viewColors.muted
        }
    }
}

/// The message reader is deliberately independent from chat navigation. Its task
/// is cancelled on selection changes, and a failed read never acknowledges mail.
private struct ActivityResultReader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @Environment(\.locusOceanTheme) private var ocean
    @Environment(\.locusCaptainDeckTheme) private var deck
    private var colors: LocusViewColors { .init(ocean: ocean, deck: deck) }
    let run: OrchestrationRun
    let title: String
    let agentName: String
    let onBack: () -> Void
    @State private var output: ChatBlock?
    @State private var loading = true
    @State private var failed = false
    @State private var loadAttempt = 0
    @State private var preview: DocumentPreviewRequest?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    private var workspace: String { run.executionPath?.nilIfEmpty ?? run.workspaceRoot ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Inbox", systemImage: "chevron.left") }
                    .accessibilityIdentifier("activity.result.back")
                Spacer()
                Button(activity.activityIsUnseen(run) ? "Mark as read" : "Mark unread") {
                    if activity.activityIsUnseen(run) { activity.markActivitySeen(run) }
                    else { activity.markActivityUnread(run) }
                }.accessibilityIdentifier("activity.result.toggleRead")
                Button {
                    guard !copyText.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(copyText.isEmpty)
                    .accessibilityIdentifier("activity.result.copy")
            }
            .font(.locus(size: 11)).buttonStyle(ActivityActionButtonStyle())
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider().overlay(colors.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.locus(size: 22, weight: .semibold)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label(agentName, systemImage: "person.crop.circle")
                            Text("·")
                            Text(Date(timeIntervalSince1970: run.completedAt ?? run.updatedAt), format: .dateTime.month(.abbreviated).day().hour().minute())
                        }.font(.locus(size: 12)).foregroundStyle(colors.muted)
                    }
                    Divider().overlay(colors.line)
                    if loading {
                        ProgressView("Loading task output…").frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if failed {
                        Label("This task’s output couldn’t be loaded.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(colors.warning)
                        Button("Try again") { loadAttempt += 1 }
                            .accessibilityIdentifier("activity.result.retry")
                    } else if let output {
                        Group {
                            if let document = output.responseParts, document.isSupported {
                                ResponsePartsView(document: document, block: output, workspacePath: workspace,
                                    onOpenWorkspaceReference: openReference)
                            } else {
                                MessageContentView(text: output.text, isStreaming: false, reasoningFormat: .none,
                                    workspacePath: workspace, onOpenWorkspaceReference: openReference)
                            }
                        }
                        .environment(\.responseOutputContext, outputContext)
                        .accessibilityIdentifier("activity.result.output")
                    } else {
                        Label("No final answer was saved for this task.", systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(colors.muted)
                    }
                    AgentInspectorRunOutputs(run: run, workspace: run.workspaceRoot ?? workspace,
                        hidesWhenEmpty: true, onOpen: openSavedOutput)
                    if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(colors.warning)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("activity.result.content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.white.opacity(0.45))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.result.reader")
        .locusSheet(item: $preview) { DocumentPreviewSheet(request: $0).appFeatureEnvironment(from: model) }
        .onDisappear { previewTask?.cancel() }
        .task(id: loadAttempt) {
            loading = true; failed = false; output = nil
            do {
                let result = try await model.loadActivityOutput(run)
                guard !Task.isCancelled else { return }
                output = result
                loading = false
                activity.markActivitySeen(run)
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; failed = true
            }
        }
    }

    private var copyText: String {
        guard let output else { return "" }
        if let document = output.responseParts, document.isSupported {
            return document.parts.map { ResponseSelectionProjection.markdown(for: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return output.text
    }

    private var outputContext: ResponseOutputContext {
        var context = model.responseOutputContext(sessionID: run.sessionID ?? "")
        context.allowsEditing = false
        context.allowsImageEditing = false
        context.openVersion = { itemID, versionID, sourceWorkspace in
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                do {
                    let items = try await model.outputsLibrary.store.list(workspace: sourceWorkspace)
                    guard !Task.isCancelled,
                          let item = items.first(where: { $0.id == itemID }),
                          let version = item.versions.first(where: { $0.id == versionID && $0.belongsTo(sessionID: nil, runID: run.id) }) else { return }
                    await previewSavedOutput(item, version: version)
                } catch { if !Task.isCancelled { previewError = "The saved output couldn’t be loaded." } }
            }
        }
        return context
    }

    private func openReference(_ reference: WorkspaceArtifactReference) {
        guard let url = MarkdownLinkPolicy.containedWorkspaceFileURL(reference.relativePath, workspacePath: workspace),
              url == reference.url.standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: url.path) else {
            previewError = "This file is no longer available in the task’s workspace."
            return
        }
        previewError = nil
        preview = DocumentPreviewRequest(url: url, title: url.lastPathComponent,
            reference: reference.documentReference ?? DocumentReference(workspace: workspace, path: reference.relativePath))
    }

    private func openSavedOutput(_ item: LibraryOutput, _ version: OutputVersion) {
        previewTask?.cancel()
        previewTask = Task { @MainActor in await previewSavedOutput(item, version: version) }
    }

    private func previewSavedOutput(_ item: LibraryOutput, version: OutputVersion) async {
        previewError = nil
        if item.isWebsite, let url = URL(string: item.target), ["https", "http"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        } else if let url = await model.outputsLibrary.store.versionURL(item, version: version) {
            guard !Task.isCancelled else { return }
            preview = DocumentPreviewRequest(url: url, title: item.title)
        } else if !Task.isCancelled {
            previewError = version.unavailableReason ?? "This saved file is no longer available."
        }
    }

}

struct ScheduleEditorView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @State private var draft: ScheduleEditorDraft
    @State private var initialDraft: ScheduleEditorDraft
    @State private var routeSelection: String
    @State private var environmentExpanded = false
    @State private var workflowExpanded = false
    @State private var discardPresented = false
    @State private var isSubmitting = false
    @State private var saveError: String?
    @State private var initialized = false
    @FocusState private var nameFocused: Bool

    init(draft: ScheduleEditorDraft) {
        var normalized = draft
        if let index = normalized.workflow.steps.firstIndex(where: { $0.type == .agent }),
           normalized.workflow.steps[index].instructionTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            normalized.workflow.steps[index].instructionTemplate = normalized.prompt
            normalized.workflow.steps[index].mode = normalized.mode
        }
        if normalized.runner == .soloSwarm { normalized.runner = .solo }
        _draft = State(initialValue: normalized)
        _initialDraft = State(initialValue: normalized)
        _routeSelection = State(initialValue: normalized.providerAccountID ?? "ollama")
        _workflowExpanded = State(initialValue: normalized.workflow.steps.count > 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identitySection
                    Divider()
                    scheduleSection
                    Divider()
                    workingFolderSection
                    Divider()
                    environmentSection
                    if model.automationWorkflowsEnabled {
                        Divider()
                        workflowSection
                    }
                    Divider()
                    permissionSummary
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("scheduleEditor.scroll")
            .disabled(isSaving)
            Divider()
            footer
        }
        .frame(width: 650, height: 580)
        .background(viewColors.surfaceCanvas)
        .interactiveDismissDisabled()
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if draft.model.isEmpty { draft.model = catalogModels.first ?? "" }
            initialDraft = draft
            nameFocused = draft.id == nil
        }
        .onChange(of: draft) { _, _ in saveError = nil }
        .onChange(of: routeSelection) { _, value in updateRoute(value) }
        .confirmationDialog("Discard changes?", isPresented: $discardPresented, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { schedule.scheduleEditorDraft = nil }
                .accessibilityIdentifier("scheduleEditor.discard")
            Button("Keep editing", role: .cancel) { }
                .accessibilityIdentifier("scheduleEditor.keepEditing")
        } message: {
            Text("Your unsaved changes to this scheduled Agent will be lost.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduleEditor")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.locus(size: 19, weight: .medium))
                .foregroundStyle(viewColors.accentAction)
                .frame(width: 42, height: 42)
                .background(viewColors.accentAction.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.id == nil ? "Create a scheduled Agent" : "Edit scheduled Agent")
                    .font(.locus(size: 17, weight: .semibold))
                Text("Set the work once. Each run continues the Agent’s dedicated chat.")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.locus(size: 11, weight: .medium))
                TextField("e.g. Morning project review", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Agent name")
                    .accessibilityIdentifier("scheduleEditor.name")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Instructions").font(.locus(size: 11, weight: .medium))
                TextEditor(text: instructionsBinding)
                    .foregroundStyle(viewColors.ink)
                    .tint(viewColors.accentAction)
                    .scrollContentBackground(.hidden)
                    .font(.locus(size: 11))
                    .frame(height: 104)
                    .padding(8)
                    .background(viewColors.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(viewColors.lineStrong) }
                    .accessibilityLabel("Instructions for each scheduled run")
                    .accessibilityIdentifier("scheduleEditor.prompt")
                Text(draft.workflow.steps.count > 1
                    ? "Instructions for the first agent step. Edit the remaining steps in Workflow below."
                    : "Describe what to do and what to report. Temporary context chips and attachments are not included.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Schedule", symbol: "calendar")
            Picker("Repeat", selection: $draft.ruleKind) {
                ForEach(ScheduleRuleKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .accessibilityIdentifier("scheduleEditor.repeat")
            scheduleFields
            HStack(spacing: 10) {
                Text("Time zone").font(.locus(size: 10))
                TextField("America/Toronto", text: $draft.timezone)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Time zone")
                    .accessibilityIdentifier("scheduleEditor.timezone")
                Button("Use local") { draft.timezone = TimeZone.current.identifier }
                    .buttonStyle(.locus(.quiet))
                    .font(.locus(size: 9))
                    .help("Use \(TimeZone.current.identifier)")
                    .accessibilityIdentifier("scheduleEditor.localTimezone")
            }
            if let scheduleIssue {
                issueLabel(scheduleIssue)
                    .accessibilityIdentifier("scheduleEditor.scheduleIssue")
            } else {
                Text(scheduleSummary)
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scheduleEditor.scheduleSummary")
            }
        }
    }

    private var selectedProfile: AgentProfile? {
        guard let id = draft.agentProfileID.flatMap(UUID.init(uuidString:)) else { return nil }
        return agentTeams.agentProfiles.first { $0.id == id }
    }

    private var workingFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Working in", symbol: "folder")
            if let profile = selectedProfile {
                Menu {
                    ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                        Button(choice.title) { selectWorkspace(choice.path) }
                    }
                    Divider()
                    Button("Choose project folder…") { chooseWorkspace() }
                } label: {
                    Label(draft.workspaceRoot == model.savedAgentHomePath(profile) ? "Agent home" : "Shared project",
                          systemImage: "folder")
                }.accessibilityIdentifier("scheduleEditor.workspaceChoice")
            }
            HStack {
                TextField("Choose a folder", text: $draft.workspaceRoot)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Working in folder")
                    .accessibilityIdentifier("scheduleEditor.workspace")
                Button("Choose…") { chooseWorkspace() }
                    .accessibilityIdentifier("scheduleEditor.chooseWorkspace")
            }
            Text(draft.workspaceRoot).font(.locus(size: 10)).foregroundStyle(viewColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("scheduleEditor.workspacePath")
            Picker("Work location", selection: $draft.executionEnvironment) {
                Text("In this folder").tag(ChatExecutionEnvironment.local)
                Text("Separate Git working copy").tag(ChatExecutionEnvironment.worktree)
            }.accessibilityIdentifier("scheduleEditor.environment")
            Text(draft.executionEnvironment == .worktree
                ? "Runs use an isolated Git working copy of this project."
                : selectedProfile.map { draft.workspaceRoot == model.savedAgentHomePath($0) } == true
                    ? "This schedule gets its own task folder inside the agent home."
                    : "Runs use this folder directly. File changes are visible to other chats using it.")
                .font(.locus(size: 9)).foregroundStyle(viewColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This folder is saved with the schedule. Changing the active chat or the agent’s default does not move its work.")
                .font(.locus(size: 9)).foregroundStyle(viewColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            disclosure("Model & execution", detail: environmentSummary,
                       symbol: "desktopcomputer", expanded: $environmentExpanded,
                       identifier: "scheduleEditor.environmentDisclosure")
            if environmentExpanded {
                Picker("Mode", selection: modeBinding) {
                    ForEach(WorkMode.automationCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("scheduleEditor.mode")
                Picker("Runner", selection: $draft.runner) {
                    ForEach(ScheduleRunner.selectableCases) { runner in Text(runner.title).tag(runner) }
                }
                .accessibilityIdentifier("scheduleEditor.runner")
                .disabled(draft.agentProfileID != nil)
                if draft.runner == .team {
                    Picker("Team", selection: $draft.teamID) {
                        Text("Choose a team").tag(String?.none)
                        if let teamID = draft.teamID, !agentTeams.agentTeams.contains(where: { $0.id.uuidString == teamID }) {
                            Text("Unavailable team").tag(Optional(teamID))
                        }
                        ForEach(agentTeams.agentTeams) { team in
                            Text(team.name).tag(Optional(team.id.uuidString))
                        }
                    }
                    .onChange(of: draft.teamID) { _, value in
                        draft.teamName = value.flatMap { id in
                            agentTeams.agentTeams.first(where: { $0.id.uuidString == id })?.name
                        } ?? ""
                    }
                    .accessibilityIdentifier("scheduleEditor.team")
                }
                Picker("Model account", selection: $routeSelection) {
                    Text("Local Ollama").tag("ollama")
                    if providerUnavailable { Text("Unavailable account").tag(routeSelection) }
                    ForEach(providerAccounts.providerAccounts) { account in
                        Text(account.displayName).tag(account.id.uuidString)
                    }
                }
                .accessibilityIdentifier("scheduleEditor.account")
                .disabled(draft.agentProfileID != nil)
                if catalogModels.isEmpty {
                    LabeledContent("Model") {
                        TextField("Exact model ID", text: $draft.model)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Model")
                            .accessibilityIdentifier("scheduleEditor.model")
                            .disabled(draft.agentProfileID != nil)
                    }
                } else {
                    Picker("Model", selection: $draft.model) {
                        Text("Choose a model").tag("")
                        ForEach(availableModels, id: \.self) { name in Text(name).tag(name) }
                    }
                    .accessibilityIdentifier("scheduleEditor.model")
                    .disabled(draft.agentProfileID != nil)
                }
                Text("Keep Locus running to process scheduled work. The selected provider receives the task when it starts.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let environmentIssue {
                issueLabel(environmentIssue)
                    .accessibilityIdentifier("scheduleEditor.environmentIssue")
            }
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            disclosure("Workflow", detail: draft.workflow.steps.count == 1
                       ? "Optional steps, conditions, and approvals"
                       : "\(draft.workflow.steps.count) steps · Runs in order",
                       symbol: "arrow.triangle.branch", expanded: $workflowExpanded,
                       identifier: "scheduleEditor.workflowDisclosure")
            if workflowExpanded { AutomationWorkflowEditorView(workflow: $draft.workflow) }
        }
    }

    private var permissionSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(viewColors.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Access now · \(model.permissionMode.title)")
                    .font(.locus(size: 11, weight: .medium))
                Text(permissionDetail)
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.textTertiary)
                Text("Each run uses the app’s permission policy at that time. Approval requests pause the run and notify you.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.textTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("scheduleEditor.permissions")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                issueLabel(saveError)
                    .accessibilityIdentifier("scheduleEditor.saveError")
            }
            HStack(spacing: 12) {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving schedule…").font(.locus(size: 10))
                } else {
                    Text(validationIssue ?? (draft.id == nil ? "The schedule starts after you create the Agent." : "Changes apply to future runs."))
                        .font(.locus(size: 9))
                        .foregroundStyle(validationIssue == nil ? viewColors.textTertiary : viewColors.warningForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scheduleEditor.validation")
                }
                Spacer(minLength: 8)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("scheduleEditor.cancel")
                Button(draft.id == nil ? "Create Agent" : "Save changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(viewColors.accentAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || validationIssue != nil)
                    .accessibilityIdentifier("scheduleEditor.save")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(viewColors.surfaceCanvas)
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.locus(size: 12, weight: .semibold))
    }

    private func disclosure(_ title: String, detail: String, symbol: String,
                            expanded: Binding<Bool>, identifier: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : LocusMotion.spatial) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(viewColors.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.locus(size: 11, weight: .semibold))
                    Text(detail).font(.locus(size: 9)).foregroundStyle(viewColors.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(viewColors.textTertiary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(identifier)
    }

    private func issueLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.locus(size: 9))
            .foregroundStyle(viewColors.warningForeground)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var scheduleFields: some View {
        switch draft.ruleKind {
        case .once:
            DatePicker("Run at", selection: $draft.oneTimeDate, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, selectedTimeZone ?? .current)
                .accessibilityIdentifier("scheduleEditor.date")
        case .daily, .weekdays:
            DatePicker("Time", selection: $draft.clockTime, displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("scheduleEditor.time")
        case .weekly:
            Picker("Day", selection: $draft.weekday) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
            }
            .accessibilityIdentifier("scheduleEditor.weekday")
            DatePicker("Time", selection: $draft.clockTime, displayedComponents: .hourAndMinute)
                .accessibilityIdentifier("scheduleEditor.time")
        case .interval:
            HStack {
                Stepper("Every \(draft.intervalEvery)", value: $draft.intervalEvery, in: 1...100_000)
                    .accessibilityIdentifier("scheduleEditor.interval")
                Picker("Unit", selection: $draft.intervalUnit) {
                    ForEach(ScheduleIntervalUnit.allCases) { unit in Text(unit.title).tag(unit) }
                }
                .labelsHidden()
                .frame(width: 120)
                .accessibilityIdentifier("scheduleEditor.intervalUnit")
            }
            DatePicker("Starting", selection: $draft.oneTimeDate, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, selectedTimeZone ?? .current)
                .accessibilityIdentifier("scheduleEditor.date")
        }
    }

    private var instructionsBinding: Binding<String> {
        Binding(get: { draft.workflow.firstAgent?.instructionTemplate ?? draft.prompt }, set: { value in
            draft.prompt = value
            if let index = draft.workflow.steps.firstIndex(where: { $0.type == .agent }) {
                draft.workflow.steps[index].instructionTemplate = value
            }
        })
    }

    private var modeBinding: Binding<WorkMode> {
        Binding(get: { draft.workflow.firstAgent?.mode ?? draft.mode }, set: { value in
            draft.mode = value
            if let index = draft.workflow.steps.firstIndex(where: { $0.type == .agent }) {
                draft.workflow.steps[index].mode = value
            }
        })
    }

    private var isSaving: Bool { isSubmitting || schedule.isSavingSchedule }
    private var selectedTimeZone: TimeZone? { TimeZone(identifier: draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var weekdayNames: [String] { ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] }

    private var validationIssue: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this Agent a name." }
        if instructionsBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add instructions for each run." }
        return scheduleIssue ?? environmentIssue
    }

    private var scheduleIssue: String? {
        guard selectedTimeZone != nil else { return "Enter a valid time zone, such as America/Toronto." }
        if draft.ruleKind == .once, draft.oneTimeDate <= Date() { return "Choose a future date and time." }
        if draft.ruleKind == .weekly, !(0...6).contains(draft.weekday) { return "Choose a day of the week." }
        if draft.ruleKind == .interval {
            let multiplier: Int = switch draft.intervalUnit {
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            case .weeks: 604_800
            }
            if draft.intervalEvery < 1 || draft.intervalEvery > 100_000 { return "Enter an interval between 1 and 100,000." }
            let seconds = draft.intervalEvery * multiplier
            if seconds < 900 { return "Use an interval of at least 15 minutes." }
            if seconds > 31_536_000 { return "Custom intervals cannot exceed one year." }
        }
        return nil
    }

    private var environmentIssue: String? {
        if draft.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a folder in Working in." }
        if draft.agentProfileID != nil, selectedProfile == nil { return "This saved agent is no longer available." }
        if providerUnavailable { return "Choose an available account in Model & execution." }
        if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.model == "No model" {
            return "Choose a model in Model & execution."
        }
        if draft.runner == .team, !agentTeams.agentTeams.contains(where: { $0.id.uuidString == draft.teamID }) {
            return "Choose an available team in Model & execution."
        }
        return nil
    }

    private var providerUnavailable: Bool {
        routeSelection != "ollama" && !providerAccounts.providerAccounts.contains { $0.id.uuidString == routeSelection }
    }

    private var environmentSummary: String {
        let folder = draft.workspaceRoot.isEmpty ? "Choose a workspace" : URL(fileURLWithPath: draft.workspaceRoot).lastPathComponent
        return "\(folder) · \(draft.executionEnvironment.title) · \(draft.runner.title) · \(draft.model.isEmpty ? "Choose a model" : draft.model)"
    }

    private var permissionDetail: String {
        switch model.permissionMode {
        case .ask: "File changes, commands, and network requests require approval."
        case .acceptEdits: "Workspace file edits can run automatically. Commands still require approval."
        case .bypass: "Available tools, including file edits, commands, and connected services, can run without approval."
        }
    }

    private var scheduleSummary: String {
        let time = draft.clockTime.formatted(date: .omitted, time: .shortened)
        let zone = draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.ruleKind {
        case .once: return "Runs once on \(formattedDate(draft.oneTimeDate)) · \(zone)"
        case .daily: return "Every day at \(time) · \(zone)"
        case .weekdays: return "Monday–Friday at \(time) · \(zone)"
        case .weekly: return "Every \(weekdayNames[min(max(draft.weekday, 0), 6)]) at \(time) · \(zone)"
        case .interval:
            let unit = draft.intervalEvery == 1 ? String(draft.intervalUnit.rawValue.dropLast()) : draft.intervalUnit.rawValue
            let start = draft.oneTimeDate <= Date() ? "when saved" : formattedDate(draft.oneTimeDate)
            return "Every \(draft.intervalEvery) \(unit), starting \(start) · \(zone)"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = selectedTimeZone ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var catalogModels: [String] {
        if routeSelection == "ollama" { return providerAccounts.installedLocalModels.map(\.name) }
        guard let id = UUID(uuidString: routeSelection),
              let account = providerAccounts.providerAccounts.first(where: { $0.id == id }) else { return [] }
        return providerAccounts.accountModels[id] ?? account.kind.curatedModels
    }

    private var availableModels: [String] {
        var names = catalogModels
        if !draft.model.isEmpty, !names.contains(draft.model) { names.insert(draft.model, at: 0) }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func updateRoute(_ value: String) {
        if value == "ollama" {
            draft.provider = "ollama"
            draft.providerAccountID = nil
        } else if let account = providerAccounts.providerAccounts.first(where: { $0.id.uuidString == value }) {
            draft.provider = account.kind.backendProvider
            draft.providerAccountID = value
        }
        if !catalogModels.contains(draft.model) { draft.model = catalogModels.first ?? "" }
    }

    private func cancel() {
        guard !isSaving else { return }
        if draft != initialDraft { discardPresented = true }
        else { schedule.scheduleEditorDraft = nil }
    }

    private func save() {
        guard !isSaving, validationIssue == nil else { return }
        isSubmitting = true
        saveError = nil
        var submitted = draft
        submitted.name = submitted.name.trimmingCharacters(in: .whitespacesAndNewlines)
        submitted.prompt = instructionsBinding.wrappedValue
        submitted.mode = modeBinding.wrappedValue
        submitted.timezone = submitted.timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousToast = model.toastMessage
        Task {
            defer { isSubmitting = false }
            do {
                if let profile = selectedProfile {
                    try model.prepareSavedAgentWorkspace(profile, workspace: submitted.workspaceRoot)
                }
                let saved = await schedule.saveSchedule(submitted)
                if !saved {
                    saveError = model.toastMessage != previousToast
                        ? model.toastMessage ?? "Could not save this schedule. Review the configuration and try again."
                        : "Could not save this schedule. Review the configuration and try again."
                }
            } catch { saveError = error.localizedDescription }
        }
    }

    private func selectWorkspace(_ path: String) {
        draft.workspaceRoot = path
        if let profile = selectedProfile {
            draft.executionEnvironment = model.savedAgentScheduleEnvironment(profile, workspace: path)
        }
    }

    private func chooseWorkspace() {
        guard let path = model.chooseSavedAgentProjectFolder() else { return }
        selectWorkspace(path)
    }
}

/// A bounded picker instead of a native `Menu`. Provider model identifiers can
/// be hundreds of characters long (especially vLLM repository paths); AppKit's
/// menu adaptor repeatedly recomputed the window layout for those strings and
/// could pin the main thread at 100% CPU. This popover owns its width and lets
/// its contents scroll, so a long route can never resize the app or its menu.
private struct ModelPickerPopover: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model")
                    .font(.locus(size: 12, weight: .bold))
                    .accessibilityIdentifier("workspace.modelPicker.popover")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.locus(size: 9, weight: .bold))
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Close model picker")
                .accessibilityIdentifier("workspace.modelPicker.close")
            }
            .padding(14)

            Divider()

            if let explanation = model.modelSelectionLockReason {
                Label(explanation, systemImage: "lock.fill")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .accessibilityIdentifier("workspace.modelPicker.lockExplanation")
                Divider()
            } else if let profile = model.currentAgentChatProfile {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Changes apply to your next message in this chat with \(profile.name).")
                        .font(.locus(size: 10))
                        .foregroundStyle(viewColors.muted)
                    if model.settings.agentChatModelSelections[model.currentSessionID] != nil {
                        Button("Use agent default") {
                            model.resetAgentChatModel()
                            dismiss()
                        }
                        .buttonStyle(.locus())
                        .font(.locus(size: 10, weight: .semibold))
                        .accessibilityIdentifier("workspace.modelPicker.agentDefault")
                    }
                }
                .padding(14)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let team = agentTeams.selectedAgentTeam {
                        teamSection(team)
                        Divider()
                    }

                    ForEach(model.modelPickerSections) { section in
                        routeSection(section)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 440)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                pickerAction(
                    "Browse Hugging Face Models…",
                    symbol: "shippingbox",
                    identifier: "workspace.modelPicker.browseHuggingFace"
                ) {
                    dismiss()
                    model.modelLibraryPresented = true
                }
                pickerAction(
                    "Refresh Models",
                    symbol: "arrow.clockwise",
                    identifier: "workspace.modelPicker.refresh"
                ) {
                    Task {
                        await model.refreshMetadata()
                        await providerAccounts.refreshAccountCatalogs(force: true)
                    }
                }
                pickerAction(
                    "Manage Accounts…",
                    symbol: "person.crop.circle",
                    identifier: "workspace.modelPicker.manageAccounts"
                ) {
                    dismiss()
                    model.presentSettings(.accounts)
                }
                pickerAction(
                    "Specialists & teams…",
                    symbol: "person.3.sequence.fill",
                    identifier: "workspace.modelPicker.manageAgentsTeams"
                ) {
                    dismiss()
                    model.presentSettings(.agents)
                }
            }
            .padding(10)
        }
        .frame(width: 380)
        .locusWorkspaceBackground()
    }

    private func teamSection(_ team: AgentTeam) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ACTIVE TEAM")
            Text(team.name)
                .font(.locus(size: 11, weight: .bold))
            ForEach(model.selectedTeamModelNames, id: \.self) { name in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "cpu")
                        .font(.locus(size: 9))
                        .foregroundStyle(viewColors.signalDeep)
                        .frame(width: 13)
                    Text(name)
                        .font(.locus(size: 8, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 14) {
                Button("Manage \(team.name)…") {
                    dismiss()
                    model.presentSettings(.agents)
                }
                .accessibilityIdentifier("workspace.modelPicker.manageTeam")
                Button("Switch to Solo") {
                    agentTeams.selectAgentTeam(nil)
                }
                .disabled(model.modelSelectionLockReason != nil)
                .accessibilityIdentifier("workspace.modelPicker.switchToSolo")
            }
            .buttonStyle(.locus())
            .font(.locus(size: 9, weight: .semibold))
        }
    }

    private func routeSection(_ section: ModelPickerSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(agentTeams.teamModeEnabled ? "SOLO · \(section.title)" : section.title.uppercased())
            if let message = section.emptyMessage {
                Text(message)
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.muted)
            }
            ForEach(section.models, id: \.self) { name in
                Button {
                    if agentTeams.teamModeEnabled { agentTeams.selectAgentTeam(nil) }
                    model.selectModel(account: section.account, model: name)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: model.isCurrentRoute(account: section.account, model: name)
                            ? "checkmark.circle.fill"
                            : "circle")
                            .font(.locus(size: 9))
                            .foregroundStyle(model.isCurrentRoute(account: section.account, model: name)
                                ? viewColors.signalDeep
                                : viewColors.muted)
                            .frame(width: 13)
                        Text(name)
                            .font(.locus(size: 9, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .disabled(model.modelSelectionLockReason != nil)
                .accessibilityLabel("Use \(name) from \(section.title)")
            }
        }
    }

    private func pickerAction(
        _ title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 9, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .padding(.horizontal, 4)
        .frame(height: 26)
        .accessibilityIdentifier(identifier)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.locus(size: 8, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(viewColors.muted)
    }
}

private struct WorkStatusStrip: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    // The provider pill names the chat's own route, which lives in these
    // feature models; observing them refreshes it when an account or agent changes.
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.locusConversationColumnAlignment) private var columnAlignment
    @ObservedObject var streamingReply: StreamingReplyState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                HStack(spacing: 8) {
                    statusPill(
                        label: model.providerLabel,
                        color: model.providerRuntimePhase.map { runtimeColor($0) } ?? viewColors.muted,
                        identifier: "workspace.modelStatus"
                    )
                    if model.isBusy, let started = model.activeWorkStartedAt {
                        Text(model.currentWorkPhase)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(elapsed(from: started, to: context.date))
                            .monospacedDigit()
                    }
                    Spacer()
                    if model.isBusy {
                        Text("~\(model.estimatedStreamingTokens.formatted()) streamed tokens")
                    }
                    if model.orchestrationState != nil {
                        Text("\(teamRunLive.teamModelCalls.formatted()) team calls")
                        if teamRunLive.teamMeteredTokens > 0 {
                            Text("\(teamRunLive.teamMeteredTokens.formatted()) hosted tokens")
                        }
                    }
                    if let info = model.sessionInfo {
                        Text("provider · \(info.promptTokens.formatted()) in / \(info.completionTokens.formatted()) out")
                            .accessibilityIdentifier("workspace.tokenStatus")
                    }
                }
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(viewColors.inkSoft)
                .frame(maxWidth: 740)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.workStatus")
            }
            // Match the composer's bounded column. Expanding or collapsing
            // side panels must not pull the two readiness dots toward the
            // window edges while the composer remains centered.
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: columnAlignment)
            .frame(height: 25)
            .locusWorkspaceBackground()
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func statusPill(label: String, color: Color, identifier: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func runtimeColor(_ phase: RuntimePhase) -> Color {
        switch phase {
        case .starting, .recovering: viewColors.warning
        case .online: viewColors.success
        case .unavailable: viewColors.coral
        }
    }
}

/// Top-level navigation between ordinary conversations and persistent agents.
/// Work mode remains a property of each conversation's composer.
struct SidebarDestinationControl: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let destination: SidebarDestination
    let select: (SidebarDestination) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(
                title: SidebarDestination.agents.title,
                selected: destination == .agents,
                identifier: "sidebar.mode.agents"
            ) {
                select(.agents)
            }

            segment(
                title: SidebarDestination.ask.title,
                selected: destination == .ask,
                identifier: "sidebar.mode.ask"
            ) {
                select(.ask)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(viewColors.paperDeep)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(viewColors.line, lineWidth: 1)
        }
        .shadow(color: viewColors.ink.opacity(0.08), radius: 2, y: 1)
        .layoutPriority(2)
        .animation(LocusMotion.spatial, value: destination)
        .help(destination == .agents ? "Showing agent conversations" : "Showing workspaces and chats")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent or Work")
        .accessibilityValue(destination.title)
        .accessibilityIdentifier("sidebar.destination")
    }

    private func segment(
        title: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.locus(size: 12, weight: .medium))
                .foregroundStyle(selected ? viewColors.white : viewColors.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule()
                            .fill(viewColors.inkSoft)
                            .shadow(color: viewColors.ink.opacity(0.16), radius: 1, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.locus())
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

struct TranscriptFollowState: Equatable {
    var isNearBottom = true
    var isFollowingOutput = true

    /// `isFollowingOutput` is the explicit pin. A layout pass can temporarily
    /// move the bottom marker more than 24 points before the matching scroll
    /// callback runs; that content growth must not masquerade as user intent.
    var permitsAutomaticScroll: Bool { isFollowingOutput }
    var showsJumpToLatest: Bool { !isNearBottom || !isFollowingOutput }

    mutating func userScrolled(upward: Bool) {
        if upward {
            isFollowingOutput = false
        } else if isNearBottom {
            isFollowingOutput = true
        }
    }

    mutating func updateBottom(isNear: Bool) {
        isNearBottom = isNear
    }

    mutating func jumpToLatest() {
        isFollowingOutput = true
    }

    mutating func detach() {
        isFollowingOutput = false
    }
}

/// Small transcripts need no estimated row heights. In particular, a handful
/// of very tall Markdown answers can make a lazy stack repeatedly revise its
/// scroll extent during a width change. Large histories still virtualize.
private struct TranscriptLayoutStack<Content: View>: View {
    let itemCount: Int
    let content: Content

    init(itemCount: Int, @ViewBuilder content: () -> Content) {
        self.itemCount = itemCount
        self.content = content()
    }

    var body: some View {
        if itemCount <= 40 {
            VStack(alignment: .leading, spacing: 0) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

private struct ConversationView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locusConversationColumnAlignment) private var columnAlignment
    let streamingReply: StreamingReplyState
    @StateObject private var scrollCoordinator = TranscriptScrollCoordinator()
    /// Owned here, outside the lazy list, so recycling a row cannot take the
    /// selection with it — and so a drag can run from one message into another.
    @StateObject private var selection = TranscriptSelectionStore()
    @State private var streamingPresentationRows: Set<String> = []
    @State private var selectedBlockSnapshots: [String: ChatBlock] = [:]
    @State private var selectedStreamingSnapshots: [String: StreamingReplySnapshot] = [:]
    @State private var selectionSources: [String: RowSelectionSource] = [:]
    @State private var deferredSelectionRows: Set<String> = []
    @State private var reusableCheckSource: ReusableCheckSource?

    var body: some View {
        GeometryReader { viewport in
            transcriptContent(viewportWidth: viewport.size.width)
        }
        .locusSheet(item: $reusableCheckSource) { source in ReusableChecksView(source: source).environmentObject(model) }
    }

    private func transcriptContent(viewportWidth: CGFloat) -> some View {
        let transcript = transcriptPresentation.snapshot
        let items = transcript.items
        let token = transcript.renderToken
        let bottomID = TranscriptScrollTarget.end(token.sessionGeneration)
        let predecessorID = items.dropLast().last?.id
        let taskResults = taskResults(in: transcript)
        return ScrollViewReader { proxy in
            let realizePredecessor: (() -> Void)? = predecessorID.map { id in
                // Discover the row's leading edge without using its still-
                // estimated height. Its actual end is measured after layout.
                { proxy.scrollTo(TranscriptScrollTarget.item(token.sessionGeneration, id), anchor: .top) }
            }
            ScrollView {
                TranscriptLayoutStack(itemCount: items.count) {
                    if transcript.isEmpty {
                        EmptyConversationView()
                            .environmentObject(model)
                    }
                    // Keep repeating rows directly visible to the lazy
                    // container's ID traversal even before they are realized.
                    ForEach(transcript.rows) { row in
                        renderRow(row, in: transcript, taskResults: taskResults)
                    }
                    if transcript.isEmpty { transcriptEnd(token: token, id: bottomID) }
                }
                .background {
                    // AppKit's pass-through overrides do not exclude the
                    // representable's SwiftUI host from hit testing.
                    TranscriptSelectionScope()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // Like the selection scope, the bridge must live inside the
                // scroll content: from the ScrollView's own background the
                // anchor is a sibling of the platform scroll view, so
                // `enclosingScrollView` is nil and streaming output is never
                // followed.
                .background {
                    #if DEBUG
                    TranscriptScrollBridge(
                        coordinator: scrollCoordinator,
                        diagnosticItemCount: items.count,
                        token: token,
                        realizeTail: {
                            if let id = token.tailID {
                                proxy.scrollTo(TranscriptScrollTarget.item(token.sessionGeneration, id))
                            }
                        },
                        realizePredecessor: realizePredecessor
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    #else
                    TranscriptScrollBridge(
                        coordinator: scrollCoordinator,
                        token: token,
                        realizeTail: {
                            if let id = token.tailID {
                                proxy.scrollTo(TranscriptScrollTarget.item(token.sessionGeneration, id))
                            }
                        },
                        realizePredecessor: realizePredecessor
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    #endif
                }
                // A lazy transcript must get its wrapping width from the
                // viewport. Letting native text's ideal size participate in
                // a flexible-width proposal can make restored panels loop
                // between incompatible row measurements.
                .frame(width: max(1, min(780, viewportWidth - 48)))
                .padding(.horizontal, 24)
                .padding(.top, transcript.isEmpty ? 0 : 24)
                .frame(maxWidth: .infinity, alignment: columnAlignment)
            }
            // The native scroll area is the transcript's accessibility
            // container. An additional lazy-stack wrapper must not substitute
            // for that viewport or its realized interactive descendants.
            .accessibilityLabel("Conversation transcript")
            .accessibilityIdentifier("conversation.scroll")
            .chatAttachmentDropTarget()
            .overlay(alignment: .bottom) {
                if scrollCoordinator.followState.showsJumpToLatest, !transcript.isEmpty {
                    Button {
                        scrollCoordinator.jumpToLatest(animated: !reduceMotion)
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(viewColors.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(viewColors.white)
                            .clipShape(Capsule())
                            .overlay { Capsule().stroke(viewColors.line, lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    }
                    .buttonStyle(.locus())
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("conversation.jumpToLatest")
                }
            }
            .onChange(of: transcript.blocks.count) { oldCount, newCount in
                // Sending a message re-engages following even after the
                // reader scrolled up, so the reply streams into view.
                if newCount > oldCount, transcript.blocks.last?.kind == .user {
                    scrollCoordinator.jumpToLatest()
                }
            }
            .onChange(of: model.transcriptSearchSelection) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .onChange(of: model.transcriptSearchQuery) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .task(id: model.activityResultReveal?.id) {
                guard let request = model.activityResultReveal,
                      request.sessionID == transcript.sessionID else { return }
                defer {
                    scrollCoordinator.finishActivityResultReveal(request.id)
                    model.finishActivityResultReveal(request.id)
                }
                // Let the loaded transcript and any inspector width change
                // settle before targeting an older answer in a lazy history.
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                scrollCoordinator.beginActivityResultReveal(request.id)
                scrollToActivityResult(request, proxy: proxy)
                try? await Task.sleep(for: .seconds(4))
            }
            .onChange(of: token.sessionGeneration) {
                selection.reset()
                streamingPresentationRows = []
                selectedBlockSnapshots = [:]
                selectedStreamingSnapshots = [:]
                selectionSources = [:]
                deferredSelectionRows = []
            }
            .onAppear {
                configureSelection(
                    for: items,
                    thinkingVisibility: transcript.thinkingVisibility
                )
            }
            .onChange(of: token.contentRevision) { _, _ in
                configureSelection(
                    for: items,
                    thinkingVisibility: transcript.thinkingVisibility
                )
            }
            .onReceive(selection.$selectedRowIDs.removeDuplicates()) { selected in
                selectedBlockSnapshots = selectedBlockSnapshots.filter { selected.contains($0.key) }
                selectedStreamingSnapshots = selectedStreamingSnapshots.filter { selected.contains($0.key) }
                for item in items where selected.contains(item.id.stableKey) && selectedBlockSnapshots[item.id.stableKey] == nil {
                    switch item {
                    case .block(let block): selectedBlockSnapshots[item.id.stableKey] = block
                    case .assistantSegment(let segment): selectedBlockSnapshots[item.id.stableKey] = segment.displayBlock
                    default: break
                    }
                    if let streamingID = streamingReply.snapshot.id, item.sourceBlockIDs.contains(streamingID) {
                        selectedStreamingSnapshots[item.id.stableKey] = streamingReply.snapshot
                    }
                }
                streamingPresentationRows = streamingPresentationRows.filter { rowID in
                    selected.contains(rowID) || items.contains { item in
                        item.id.stableKey == rowID && model.activeStreamingAssistantID.map { item.sourceBlockIDs.contains($0) } == true
                    }
                }
            }
            .onChange(of: selection.selectedRowIDs) { _, _ in
                configureSelection(for: items, thinkingVisibility: transcript.thinkingVisibility)
            }
            .onChange(of: transcript.thinkingVisibility) { _, visibility in
                configureSelection(for: items, thinkingVisibility: visibility)
            }
            .environment(\.runInTerminalAction) { [weak model] command in
                model?.runCommandInTerminal(command)
            }
        }
    }

    private func taskResults(in transcript: TranscriptPresentationSnapshot) -> [UUID: TranscriptTaskResult] {
        var records = Dictionary(runs.orchestrationRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        records.merge(runs.runDetailsByID, uniquingKeysWith: { _, detail in detail })
        return ChatTranscriptBuilder.taskResults(in: transcript.blocks, runs: Array(records.values),
            session: sessionCatalog.snapshot.sessionsByID[transcript.sessionID], profiles: agentTeams.agentProfiles)
    }

    private func renderRow(_ row: TranscriptRenderRow, in transcript: TranscriptPresentationSnapshot,
                           taskResults: [UUID: TranscriptTaskResult]) -> some View {
        let item = row.item
        let token = transcript.renderToken
        let content = presentationRow(
            item,
            assistantMarkerItemIDs: transcript.assistantMarkerItemIDs,
            assistantActionItemIDs: transcript.assistantActionItemIDs,
            toolActivityVisibility: transcript.toolActivityVisibility,
            thinkingVisibility: transcript.thinkingVisibility,
            taskResults: taskResults
        )
            .padding(.top, topSpacing(
                before: item,
                previous: row.index > 0 ? transcript.items[row.index - 1] : nil,
                toolActivityVisibility: transcript.toolActivityVisibility,
                thinkingVisibility: transcript.thinkingVisibility
            ))
            .background {
                if item.id == token.tailID {
                    TranscriptTailLayoutProbe(coordinator: scrollCoordinator, token: token, kind: .content)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if row.index == transcript.items.count - 2 {
                    TranscriptTailLayoutProbe(coordinator: scrollCoordinator, token: token, kind: .predecessor)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        return VStack(alignment: .leading, spacing: 0) {
            content
            if item.id == token.tailID {
                transcriptEnd(token: token, id: .end(token.sessionGeneration))
            }
        }
        #if DEBUG
        .background {
            if model.pendingDispatchPlan != nil, TranscriptRowGeometryDiagnostics.enabled {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            TranscriptRowGeometryDiagnostics.record(row: row.index, token: token,
                                frame: geometry.frame(in: .global), event: "appear")
                        }
                        .onChange(of: geometry.frame(in: .global)) { _, frame in
                            TranscriptRowGeometryDiagnostics.record(row: row.index, token: token,
                                frame: frame, event: "geometry")
                        }
                        .onDisappear {
                            TranscriptRowGeometryDiagnostics.record(row: row.index, token: token,
                                frame: geometry.frame(in: .global), event: "disappear")
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        #endif
        .id(row.id)
    }

    /// Keeps the store's idea of the transcript in step with what is rendered,
    /// and teaches it how to read a row that has not been realized — which is
    /// what lets Copy return a whole passage after a long scroll.
    private func configureSelection(
        for items: [TranscriptPresentationItem],
        thinkingVisibility: ThinkingVisibility
    ) {
        let sources = Dictionary(
            items.compactMap { item -> (String, RowSelectionSource)? in
                guard let source = Self.selectionSource(of: item) else { return nil }
                return (item.id.stableKey, source)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let workspacePath = model.workspacePath
        let sessionID = transcriptPresentation.snapshot.sessionID
        let affectedRows = Set(selectionSources.keys).union(sources.keys).union(deferredSelectionRows)
        for rowID in affectedRows where selectionSources[rowID] != sources[rowID] || deferredSelectionRows.contains(rowID) {
            if selection.selectedRowIDs.contains(rowID) { deferredSelectionRows.insert(rowID); continue }
            let expected = sources[rowID].map { Self.spans(for: $0, rowID: rowID, thinkingVisibility: thinkingVisibility,
                workspacePath: workspacePath, sessionID: sessionID) } ?? []
            selection.retainSpanIDs(in: rowID, keeping: Set(expected.map(\.id)))
            deferredSelectionRows.remove(rowID)
        }
        selectionSources = sources
        selection.spanProvider = { rowID in
            guard let source = sources[rowID] else { return [] }
            return Self.spans(for: source, rowID: rowID, thinkingVisibility: thinkingVisibility,
                workspacePath: workspacePath, sessionID: sessionID)
        }
        selection.onDragActiveChange = { active in
            scrollCoordinator.setSelectionDragActive(active)
        }
        selection.onViewportAnchorChange = { anchor in
            scrollCoordinator.setSelectionViewportAnchor(anchor)
        }
        selection.syncRows(items.map(\.id.stableKey))
    }

    private enum RowSelectionSource: Equatable {
        /// A user bubble renders its text as one Markdown document.
        case whole(String)
        /// An assistant answer is split into reasoning and visible segments
        /// before rendering, and each visible one is its own subtree.
        case assistant(String, AssistantReasoningFormat)
        case structured(ResponseDocument, String?)
    }

    private func transcriptEnd(token: TranscriptRenderToken, id: TranscriptScrollTarget) -> some View {
        // Realize terminal content and its existing breathing room together.
        // An independent lazy footer can remain unrealized after a row pin.
        Color.clear
            .frame(height: 41)
            .id(id)
            .background {
                TranscriptTailLayoutProbe(coordinator: scrollCoordinator, token: token, kind: .end)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private static func selectionSource(of item: TranscriptPresentationItem) -> RowSelectionSource? {
        switch item {
        case .block(let block):
            switch block.kind {
            case .user: .whole(block.text)
            case .assistant:
                if block.assistantPhase == .commentary { nil }
                else if let document = block.responseParts, document.isSupported { .structured(document, block.sourceItemID) }
                else { .assistant(block.text, block.reasoningFormat ?? .legacyTags) }
            default: nil
            }
        case .assistantSegment(let segment):
            if segment.sourceBlock.assistantPhase == .commentary { nil }
            else if let document = segment.sourceBlock.responseParts, document.isSupported { .structured(document, segment.sourceBlock.sourceItemID) }
            else { .assistant(segment.text, segment.sourceBlock.reasoningFormat ?? .legacyTags) }
        case .toolGroup, .thinkingGroup:
            nil
        }
    }

    /// Must reproduce exactly what the rendered leaves register, or a row
    /// filled in from here would not line up with the same row once it scrolls
    /// back into view.
    private static func spans(
        for source: RowSelectionSource,
        rowID: String,
        thinkingVisibility: ThinkingVisibility,
        workspacePath: String,
        sessionID: String
    ) -> [TranscriptSelectionSpan] {
        switch source {
        case .whole(let text):
            guard !text.isEmpty else { return [] }
            return Array(
                MarkdownSelectionProjection.spans(
                    for: FinishedMarkdownCache.blocks(for: text),
                    rootPath: [0],
                    firstSeparator: "\n\n",
                    rowID: rowID
                ).values
            )
        case .structured(let document, let itemID):
            return ResponseSelectionProjection.spans(document: document, rowID: rowID,
                workspacePath: workspacePath, sessionID: sessionID, itemID: itemID)
        case .assistant(let text, let format):
            var result: [TranscriptSelectionSpan] = []
            let segments = AssistantSegment.rendered(from: text, mode: thinkingVisibility, reasoningFormat: format)
            for (index, segment) in segments.enumerated() {
                guard case .visible(let body) = segment, !body.isEmpty else { continue }
                result += MarkdownSelectionProjection.spans(
                    for: FinishedMarkdownCache.blocks(for: body),
                    rootPath: [index],
                    firstSeparator: "\n\n",
                    rowID: rowID
                ).values
            }
            return result
        }
    }

    @ViewBuilder
    private func presentationRow(
        _ item: TranscriptPresentationItem,
        assistantMarkerItemIDs: Set<TranscriptPresentationItem.ID>,
        assistantActionItemIDs: Set<TranscriptPresentationItem.ID>,
        toolActivityVisibility: ToolActivityVisibility,
        thinkingVisibility: ThinkingVisibility,
        taskResults: [UUID: TranscriptTaskResult]
    ) -> some View {
        switch item {
        case .block(let block):
            if block.kind == .tool, let tool = block.tool {
                detailedToolRow(
                    tool,
                    showsAssistantMarker: assistantMarkerItemIDs.contains(item.id)
                )
            } else {
                blockRow(
                    displayBlock: block,
                    sourceBlock: block,
                    presentationID: item.id,
                    accessibilityIdentifier: block.completion == nil
                        ? "message.\(block.id.uuidString)"
                        : "turnCompletion.\(block.id.uuidString)",
                    thinkingVisibility: thinkingVisibility,
                    showsAssistantMarker: assistantMarkerItemIDs.contains(item.id),
                    showsAssistantActions: assistantActionItemIDs.contains(item.id),
                    taskResult: taskResults[block.id]
                )
            }
        case .assistantSegment(let segment):
            blockRow(
                displayBlock: segment.displayBlock,
                sourceBlock: segment.sourceBlock,
                presentationID: item.id,
                accessibilityIdentifier: segment.id.ordinal == 0
                    ? "message.\(segment.id.sourceBlockID.uuidString)"
                    : "message.\(segment.id.sourceBlockID.uuidString).segment.\(segment.id.ordinal)",
                thinkingVisibility: thinkingVisibility,
                showsAssistantMarker: assistantMarkerItemIDs.contains(item.id),
                showsAssistantActions: assistantActionItemIDs.contains(item.id),
                taskResult: taskResults[segment.sourceBlock.id]
            )
        case .toolGroup(let id, let tools):
            ToolActivityView(
                groupID: id,
                tools: tools,
                visibility: toolActivityVisibility,
                accent: model.effectiveAccent,
                showsMarker: assistantMarkerItemIDs.contains(item.id),
                onExpansionChange: scrollCoordinator.detach
            )
        case .thinkingGroup(let id, let entries):
            ThinkingActivityView(
                groupID: id,
                entries: entries,
                visibility: thinkingVisibility,
                accent: model.effectiveAccent,
                showsMarker: assistantMarkerItemIDs.contains(item.id),
                onExpansionChange: scrollCoordinator.detach
            )
        }
    }

    private func detailedToolRow(
        _ tool: ToolPayload,
        showsAssistantMarker: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAssistantMarker {
                LocusMessageMarker(accent: model.effectiveAccent)
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            ToolCardView(tool: tool)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func blockRow(
        displayBlock: ChatBlock,
        sourceBlock: ChatBlock,
        presentationID: TranscriptPresentationItem.ID,
        accessibilityIdentifier: String,
        thinkingVisibility: ThinkingVisibility,
        showsAssistantMarker: Bool,
        showsAssistantActions: Bool,
        taskResult: TranscriptTaskResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = taskResult {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Task result", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(viewColors.success)
                        Spacer(minLength: 8)
                        if let date = result.completedAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(viewColors.muted)
                        }
                    }
                    .font(.locus(size: 8, weight: .medium))
                    Text(result.title).font(.locus(size: 11, weight: .semibold))
                    if let name = result.agentName {
                        Text("Completed by \(name)")
                            .font(.locus(size: 8)).foregroundStyle(viewColors.muted)
                    }
                    Divider().padding(.top, 5)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("taskResult.header.\(result.runID)")
            }
            if sourceBlock.kind == .assistant,
               (sourceBlock.id == model.activeStreamingAssistantID
                || (streamingPresentationRows.contains(presentationID.stableKey)
                    && selection.selectedRowIDs.contains(presentationID.stableKey)))
            {
                ActiveAssistantBlockView(
                    reply: streamingReply,
                    frozenSnapshot: selectedStreamingSnapshots[presentationID.stableKey],
                    thinkingVisibility: thinkingVisibility,
                    accent: model.effectiveAccent,
                    workspacePath: model.workspacePath,
                    showsMarker: showsAssistantMarker,
                    isReasoningActivity: sourceBlock.sourceItemID != nil
                        && sourceBlock.assistantPhase == nil,
                    selectionStore: selection,
                    selectionRowID: presentationID.stableKey,
                    onOpenWorkspaceReference: model.openWorkspaceReference
                )
                .onAppear { streamingPresentationRows.insert(presentationID.stableKey) }
            } else {
                MessageBlockView(
                    block: selectedBlockSnapshots[presentationID.stableKey] ?? displayBlock,
                    thinkingVisibility: thinkingVisibility,
                    accent: model.effectiveAccent,
                    workspacePath: model.workspacePath,
                    actionsDisabled: model.isBusy || model.hasPendingPermission,
                    canRewind: model.canRewind(to: sourceBlock),
                    canRegenerate: showsAssistantActions && model.canRegenerate(sourceBlock),
                    showsAssistantMarker: showsAssistantMarker,
                    showsAssistantActions: showsAssistantActions,
                    accessibilityIdentifier: accessibilityIdentifier,
                    selectionStore: selection,
                    selectionRowID: presentationID.stableKey,
                    onCopy: { format in
                        if sourceBlock.kind == .assistant {
                            model.copyResponse(sourceBlock.text, format: format, reasoningFormat: sourceBlock.reasoningFormat ?? .legacyTags)
                        } else {
                            model.copyMessage(sourceBlock.text)
                        }
                    },
                    onUseAsDraft: {
                        let draft = sourceBlock.kind == .assistant
                            ? AssistantSegment.copyableText(from: sourceBlock.text, reasoningFormat: sourceBlock.reasoningFormat ?? .legacyTags)
                            : sourceBlock.text
                        model.useAsDraft(draft)
                    },
                    onMakeReusableCheck: { reusableCheckSource = ReusableCheckSource(correction: sourceBlock.text, messageIndex: sourceBlock.historyIndex, runID: sourceBlock.runID) },
                    onRewind: { model.rewind(to: sourceBlock) },
                    onRegenerate: { model.retryLastResponse() },
                    onOpenWorkspaceReference: model.openWorkspaceReference
                )
                .equatable()
                .environment(\.responseOutputContext, model.responseOutputContext(sessionID: transcriptPresentation.snapshot.sessionID))
                .onAppear { if !selection.selectedRowIDs.contains(presentationID.stableKey) { streamingPresentationRows.remove(presentationID.stableKey) } }
            }
            if sourceBlock.kind == .user, let runID = sourceBlock.runID {
                if runKind(for: runID) == "team" {
                    TeamRunBoardView(runID: runID, request: sourceBlock.text)
                        .environmentObject(model)
                        .id("team-board-\(runID)")
                } else {
                    SoloSwarmPanelView(runID: runID)
                        .environmentObject(model)
                        .id("solo-swarm-panel-\(runID)")
                }
            }
        }
        .padding(taskResult == nil ? 0 : 14)
        .background {
            if let request = model.activityResultReveal,
               request.sessionID == transcriptPresentation.snapshot.sessionID,
               request.blockID == sourceBlock.id,
               transcriptPresentation.snapshot.items.first(where: { item in
                   switch item {
                   case .block(let block): return block.id == sourceBlock.id
                   case .assistantSegment(let segment): return segment.sourceBlock.id == sourceBlock.id
                   case .toolGroup, .thinkingGroup: return false
                   }
               })?.id == presentationID {
                TranscriptActivityResultProbe(coordinator: scrollCoordinator,
                    token: transcriptPresentation.snapshot.renderToken, requestID: request.id)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background {
            if taskResult != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewColors.white.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(viewColors.line, lineWidth: 1)
                    }
            }
        }
        .overlay {
            if let request = model.activityResultReveal,
               request.sessionID == transcriptPresentation.snapshot.sessionID,
               request.blockID == sourceBlock.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(viewColors.accentAction.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(viewColors.accentAction, lineWidth: 2)
                    }
                    .padding(-7)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Task result opened from Activity Center")
                    .accessibilityIdentifier("activity.resultHighlight.\(request.runID)")
            } else if let style = model.transcriptMatchStyle(for: sourceBlock.id) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        style == .current
                            ? viewColors.signalDeep
                            : viewColors.lineStrong.opacity(0.7),
                        lineWidth: style == .current ? 2 : 1
                    )
                    .padding(-7)
                    .allowsHitTesting(false)
            }
        }
    }

    private func runKind(for runID: String) -> String {
        if model.turnDispatchedTeamRunID == runID { return "team" }
        if runs.selectedOrchestrationRun?.id == runID {
            return runs.selectedOrchestrationRun?.runKind ?? "solo"
        }
        if let kind = runs.runDetailsByID[runID]?.runKind { return kind }
        return runs.orchestrationRuns.first(where: { $0.id == runID })?.runKind ?? "solo"
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = model.currentTranscriptMatch else { return }
        let destination = transcriptPresentation.snapshot.items.first(where: {
            $0.sourceBlockIDs.contains(match)
        })?.id ?? .block(match)
        withAnimation(LocusMotion.scroll) {
            proxy.scrollTo(TranscriptScrollTarget.item(
                transcriptPresentation.snapshot.renderToken.sessionGeneration, destination
            ), anchor: .center)
        }
    }

    private func scrollToActivityResult(_ request: ActivityResultReveal, proxy: ScrollViewProxy) {
        let transcript = transcriptPresentation.snapshot
        guard request.sessionID == transcript.sessionID,
              let destination = transcript.items.first(where: { item in
                  switch item {
                  case .block(let block): return block.id == request.blockID
                  case .assistantSegment(let segment): return segment.sourceBlock.id == request.blockID
                  case .toolGroup, .thinkingGroup: return false
                  }
              })?.id else { return }
        // Realize the row; its native layout probe settles the actual top once
        // lazy estimates and the inspector's width change have been resolved.
        proxy.scrollTo(TranscriptScrollTarget.item(
            transcript.renderToken.sessionGeneration, destination
        ), anchor: .top)
    }

    private func topSpacing(
        before item: TranscriptPresentationItem,
        previous: TranscriptPresentationItem?,
        toolActivityVisibility: ToolActivityVisibility,
        thinkingVisibility: ThinkingVisibility
    ) -> CGFloat {
        guard let previous else { return 0 }
        if isTurnBoundary(item) || isTurnBoundary(previous) { return 24 }
        if isCompactFlowItem(
            item,
            toolActivityVisibility: toolActivityVisibility,
            thinkingVisibility: thinkingVisibility
        ) || isCompactFlowItem(
            previous,
            toolActivityVisibility: toolActivityVisibility,
            thinkingVisibility: thinkingVisibility
        ) { return 14 }
        return 24
    }

    private func isTurnBoundary(_ item: TranscriptPresentationItem) -> Bool {
        guard case .block(let block) = item else { return false }
        return block.kind == .user || block.completion != nil
    }

    private func isCompactFlowItem(
        _ item: TranscriptPresentationItem,
        toolActivityVisibility: ToolActivityVisibility,
        thinkingVisibility: ThinkingVisibility
    ) -> Bool {
        switch item {
        case .assistantSegment(let segment):
            return segment.sourceBlock.assistantPhase == .commentary
        case .toolGroup:
            return toolActivityVisibility == .collapsed
        case .thinkingGroup:
            return thinkingVisibility == .collapsed
        case .block:
            return false
        }
    }
}

struct TranscriptScrollMetrics {
    /// Bounds overlap does not imply gesture ownership: compact sidebars and
    /// floating panels can cover the transcript in the same window. Resolve
    /// the native frontmost hit, including nested text/code scroll responders.
    @MainActor
    static func ownsWheelLocation(
        _ locationInWindow: NSPoint,
        eventWindow: NSWindow?,
        scrollView: NSScrollView
    ) -> Bool {
        guard let window = scrollView.window, eventWindow === window,
              let root = window.contentView,
              scrollView.bounds.contains(scrollView.convert(locationInWindow, from: nil))
        else { return false }
        // NSView.hitTest takes a point in its superview's coordinates.
        let point = root.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        guard let hit = root.hitTest(point) else { return false }
        return hit === scrollView || hit.isDescendant(of: scrollView)
    }

    static func dominantVerticalWheelDelta(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        legacyDeltaX: CGFloat,
        legacyDeltaY: CGFloat
    ) -> CGFloat? {
        // Synthetic wheels and older AppKit releases can leave the precise
        // scrolling deltas at zero while still populating deltaX/deltaY.
        let deltaX = scrollingDeltaX == 0 ? legacyDeltaX : scrollingDeltaX
        let deltaY = scrollingDeltaY == 0 ? legacyDeltaY : scrollingDeltaY
        guard abs(deltaY) > 0, abs(deltaY) >= abs(deltaX) else { return nil }
        return deltaY
    }

    static func bottomDistance(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - visibleRect.maxY, 0)
        }
        return max(visibleRect.minY - documentBounds.minY, 0)
    }

    static func bottomOriginY(
        documentBounds: CGRect,
        viewportHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - viewportHeight, documentBounds.minY)
        }
        return documentBounds.minY
    }
}

#if DEBUG
@MainActor
private enum TranscriptRowGeometryDiagnostics {
    static let enabled = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            && environment["LOCUS_TESTING_TRANSCRIPT_GEOMETRY"] == "1"
    }()
    private static var records = 0

    static func record(row: Int, token: TranscriptRenderToken, frame: CGRect, event: String) {
        guard enabled, records < 128 else { return }
        records += 1
        let metadata: [String: Any] = ["record": records, "row": row, "event": event,
            "generation": token.sessionGeneration, "revision": token.contentRevision,
            "frame": [frame.minX, frame.minY, frame.width, frame.height]]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? FileHandle.standardError.write(contentsOf: Data(("LocusTranscriptRowGeometry " + json + "\n").utf8))
        }
    }
}
#endif

enum TranscriptTailLayoutKind: Equatable { case content, end, predecessor }

/// Observes the native viewport and coalesces following to one logical-bottom
/// request per display refresh. LazyVStack's native document extent is only an
/// estimate; SwiftUI must resolve the target and realize its actual rows.
@MainActor
final class TranscriptScrollCoordinator: ObservableObject {
    @Published private(set) var followState = TranscriptFollowState()

    private struct SelectionLayoutGeometry: Equatable {
        let token: TranscriptRenderToken
        let glyph: NSRect
        let document: NSRect
        let viewportSize: NSSize
    }

    private struct SelectionViewportOwnership {
        let anchor: TranscriptSelectionViewportAnchor
        let generation: UInt64
        let attachment: UInt64
        let readerRevision: UInt64
        let glyphOffsetY: CGFloat
        var lastRestoredGeometry: SelectionLayoutGeometry?
    }

    private var selectionViewportOwnership: SelectionViewportOwnership?
    private var activityResultOwnership: (id: UUID, generation: UInt64, readerRevision: UInt64)?
    private weak var activityResultProbe: TranscriptTailLayoutView?
    private var isRestoringActivityResult = false
    private var isRestoringSelectionViewport = false
    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var displayLink: CADisplayLink?
    private var pinPending = false
    private var isSelectionDragActive = false
    private var isProgrammaticScroll = false
    private var isUserLiveScrolling = false
    private var isRoutingVerticalWheel = false
    private var lastOriginY: CGFloat = 0
    private var scrollToBottomTarget: (() -> Void)?
    private var realizeTailTarget: (() -> Void)?
    private var realizePredecessorTarget: (() -> Void)?
    private var renderToken: TranscriptRenderToken?
    private weak var bridgeAnchor: NSView?
    private var attachmentRevision: UInt64 = 0
    private var observerSessionGeneration: UInt64?
    private var readerIntentRevision: UInt64 = 0
    private var pendingSessionFollowReset: (generation: UInt64, readerRevision: UInt64)?
    private struct TailProbeRegistration {
        weak var view: TranscriptTailLayoutView?
        let token: TranscriptRenderToken
        let kind: TranscriptTailLayoutKind
    }

    // A representable can register before its token's bridge update. Keep
    // those future registrations without allowing a late older row to replace
    // the current row's probes. These entries never retain native views.
    private var tailProbeRegistrations: [TailProbeRegistration] = []
    private var contentProbe: TranscriptTailLayoutView? { tailProbe(kind: .content) }
    private var endProbe: TranscriptTailLayoutView? { tailProbe(kind: .end) }
    private var predecessorProbe: TranscriptTailLayoutView? { tailProbe(kind: .predecessor) }
    private var contentRect: NSRect?
    private var endRect: NSRect?
    private var predecessorRect: NSRect?
    private var realizationRequested = false
    private struct ContainerLayoutGeometry: Equatable {
        let container: NSRect
        let document: NSRect
        let viewportSize: NSSize
    }

    private var realizationGeometry: [(layout: ContainerLayoutGeometry, viewport: NSRect, predecessor: NSRect?)] = []
    private var pendingSessionViewportReset: UInt64?
    private var containerLayoutAcknowledgement: (
        token: TranscriptRenderToken, attachment: UInt64, geometry: ContainerLayoutGeometry
    )?
    private var lastViewportSize: NSSize = .zero
    private var lastAlignment: (token: TranscriptRenderToken, end: NSRect, viewport: NSRect, document: NSRect)?
    // Lifecycle cancellation must not discard content queued before an
    // ordinary pin. Pin completions have a separate latest-request serial.
    private var scrollIntentRevision: UInt64 = 0
    private var pinCompletionRevision: UInt64 = 0
    #if DEBUG
    private let geometryDiagnosticsEnabled = {
        let environment = ProcessInfo.processInfo.environment
        return (environment["LOCUS_UI_TESTING"] == "1"
            && environment["LOCUS_UI_TESTING_TRANSCRIPT_GEOMETRY"] == "1")
            || (environment["XCTestConfigurationFilePath"] != nil
                && environment["LOCUS_TESTING_TRANSCRIPT_GEOMETRY"] == "1")
    }()
    private var geometryDiagnosticRecords = 0
    private var geometryDiagnosticDisplayTicks = 0
    private var geometryDiagnosticItemCount = 0
    private let geometryDiagnosticStartedAt = ProcessInfo.processInfo.systemUptime
    private weak var geometryDiagnosticAnchor: NSView?

    func setDiagnosticItemCount(_ count: Int) {
        guard geometryDiagnosticsEnabled else { return }
        guard geometryDiagnosticItemCount != count else { return }
        geometryDiagnosticItemCount = count
        recordGeometry("items.changed")
    }

    /// Opt-in fixture diagnostics only. Never inspect text, accessibility
    /// values, model identifiers, URLs, or object descriptions, and never
    /// force layout while measuring the layout/scroll transition itself.
    private func recordGeometry(_ event: String, target: NSPoint? = nil) {
        guard geometryDiagnosticsEnabled, geometryDiagnosticRecords < 96 else { return }
        geometryDiagnosticRecords += 1
        func rect(_ value: NSRect) -> [Double] {
            [Double(value.origin.x), Double(value.origin.y),
             Double(value.size.width), Double(value.size.height)]
        }
        var record: [String: Any] = [
            "event": event,
            "record": geometryDiagnosticRecords,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - geometryDiagnosticStartedAt,
            "itemCount": geometryDiagnosticItemCount,
            "following": followState.isFollowingOutput,
            "nearBottom": followState.isNearBottom,
            "programmaticScroll": isProgrammaticScroll,
            "pinPending": pinPending,
            "attached": scrollView != nil,
            "attachmentRevision": attachmentRevision,
            "sessionGeneration": renderToken?.sessionGeneration ?? 0,
            "contentRevision": renderToken?.contentRevision ?? 0,
            "realizationRequested": realizationRequested,
            "containerLayoutAcknowledged": hasCurrentContainerLayout,
            "displayTicks": geometryDiagnosticDisplayTicks,
        ]
        if let contentRect { record["tailContentRect"] = rect(contentRect) }
        if let endRect { record["tailEndRect"] = rect(endRect) }
        if let predecessorRect { record["predecessorRect"] = rect(predecessorRect) }
        if let scrollView {
            record["scrollFrame"] = rect(scrollView.frame)
            record["scrollBounds"] = rect(scrollView.bounds)
            record["clipBounds"] = rect(scrollView.contentView.bounds)
            record["documentVisibleRect"] = rect(scrollView.documentVisibleRect)
            record["windowContentSize"] = scrollView.window.map {
                [Double($0.contentLayoutRect.width), Double($0.contentLayoutRect.height)]
            }
            record["windowVisible"] = scrollView.window?.isVisible ?? false
            record["windowUnoccluded"] = scrollView.window?.occlusionState.contains(.visible) ?? false
        }
        if let documentView {
            record["documentFrame"] = rect(documentView.frame)
            record["documentBounds"] = rect(documentView.bounds)
            record["documentFlipped"] = documentView.isFlipped
            record["documentSubviewCount"] = documentView.subviews.count
            if let anchor = geometryDiagnosticAnchor {
                record["anchorBounds"] = rect(anchor.bounds)
                record["anchorInDocument"] = rect(anchor.convert(anchor.bounds, to: documentView))
                record["anchorInWindow"] = anchor.window != nil
            }
        }
        if let target { record["targetOrigin"] = [Double(target.x), Double(target.y)] }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? FileHandle.standardError.write(contentsOf: Data(
                ("LocusTranscriptGeometry " + json + "\n").utf8
            ))
        }
    }
    #endif

    func setBottomTarget(_ target: @escaping () -> Void) {
        scrollToBottomTarget = target
    }

    /// Installing a projection is not a layout acknowledgment. The two probes
    /// below must report matching, attached native geometry before it can settle.
    @discardableResult
    func installRenderTarget(
        _ token: TranscriptRenderToken,
        realizeTail: @escaping () -> Void,
        realizePredecessor: (() -> Void)? = nil,
        scrollToBottom: (() -> Void)? = nil
    ) -> Bool {
        // A superseded representable must not replace current callbacks,
        // invalidate geometry, or re-arm a conversation's default following.
        guard admitsRenderToken(token) else { return false }
        realizeTailTarget = realizeTail
        realizePredecessorTarget = realizePredecessor
        scrollToBottomTarget = scrollToBottom
        // Same-projection updates may carry a fresh ScrollViewReader proxy.
        // Refresh its callbacks without treating that as a new projection.
        guard renderToken != token else { return true }
        let previousGeneration = renderToken?.sessionGeneration
        let changedSession = previousGeneration != token.sessionGeneration
        if changedSession {
            selectionViewportOwnership = nil
            // Content revisions may coalesce before SwiftUI drains this
            // generation's callback. Retain its original reader lease until
            // the latest matching projection consumes it, never re-arm it on
            // a same-conversation update after the reader has taken control.
            pendingSessionFollowReset = (token.sessionGeneration, readerIntentRevision)
            if previousGeneration != nil {
                pendingSessionViewportReset = token.sessionGeneration
            }
        }
        renderToken = token
        pruneTailProbeRegistrations()
        scrollIntentRevision &+= 1
        isProgrammaticScroll = false
        pinPending = false
        displayLink?.isPaused = true
        contentRect = nil
        endRect = nil
        predecessorRect = nil
        realizationRequested = false
        realizationGeometry.removeAll(keepingCapacity: true)
        containerLayoutAcknowledgement = nil
        lastAlignment = nil
        if changedSession { attachmentRevision &+= 1 }
        // NSViewRepresentable updates occur inside SwiftUI's graph update.
        // Publish follow-state changes only after that update, with its token.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderToken == token else { return }
            if let pending = self.pendingSessionFollowReset,
               pending.generation == token.sessionGeneration {
                self.pendingSessionFollowReset = nil
                // Attaching native views does not change this reader epoch.
                // A selection, gesture, detach or explicit jump does: none
                // may be overwritten by a previously queued session default.
                if pending.readerRevision == self.readerIntentRevision {
                    self.isUserLiveScrolling = false
                    self.isSelectionDragActive = false
                    self.isRoutingVerticalWheel = false
                    self.mutateState { $0 = TranscriptFollowState() }
                }
            }
            self.updateNearBottom()
            self.contentMayHaveChanged()
        }
        return true
    }

    func registerTailProbe(_ view: TranscriptTailLayoutView) {
        pruneTailProbeRegistrations()
        // A reused representable has only its newest registration. Removing
        // an old key must not remove a different view at the current key.
        tailProbeRegistrations.removeAll { $0.view === view }
        guard let token = view.token, admitsRenderToken(token) else { return }
        tailProbeRegistrations.removeAll { $0.token == token && $0.kind == view.kind }
        tailProbeRegistrations.append(TailProbeRegistration(view: view, token: token, kind: view.kind))
    }

    func unregisterTailProbe(_ view: TranscriptTailLayoutView) {
        if contentProbe === view { contentRect = nil }
        if endProbe === view { endRect = nil }
        if predecessorProbe === view { predecessorRect = nil }
        tailProbeRegistrations.removeAll { $0.view == nil || $0.view === view }
        // Dismantling is inside a SwiftUI graph mutation. Do not publish or
        // schedule a replacement scroll from this cleanup callback.
    }

    private func admitsRenderToken(_ token: TranscriptRenderToken) -> Bool {
        guard let current = renderToken else { return true }
        if token.sessionGeneration != current.sessionGeneration {
            return token.sessionGeneration > current.sessionGeneration
        }
        if token.contentRevision != current.contentRevision {
            return token.contentRevision > current.contentRevision
        }
        return token == current
    }

    private func pruneTailProbeRegistrations() {
        tailProbeRegistrations.removeAll {
            guard let view = $0.view else { return true }
            return view.token != $0.token || view.kind != $0.kind || !admitsRenderToken($0.token)
        }
    }

    private func tailProbe(kind: TranscriptTailLayoutKind) -> TranscriptTailLayoutView? {
        pruneTailProbeRegistrations()
        guard let token = renderToken else { return nil }
        return tailProbeRegistrations.first { $0.token == token && $0.kind == kind }?.view
    }

    func tailDidLayout(
        token: TranscriptRenderToken, kind: TranscriptTailLayoutKind,
        rect: NSRect, in scroll: NSScrollView
    ) {
        guard token == renderToken, scroll === scrollView,
              !rect.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return }
        let previous: NSRect?
        switch kind {
        case .content: previous = contentRect; contentRect = rect
        case .end: previous = endRect; endRect = rect
        case .predecessor: previous = predecessorRect; predecessorRect = rect
        }
        updateNearBottom()
        if measuredTailIsAtBottom() {
            isProgrammaticScroll = false
            lastOriginY = scroll.contentView.bounds.origin.y
        } else if previous != rect {
            schedulePin()
        }
        #if DEBUG
        switch kind {
        case .content: recordGeometry("tail.contentLaidOut")
        case .end: recordGeometry("tail.endLaidOut")
        case .predecessor: recordGeometry("predecessor.laidOut")
        }
        #endif
    }

    var layoutAttachmentRevision: UInt64 { attachmentRevision }

    private var hasCurrentContainerLayout: Bool {
        guard let renderToken, let acknowledgement = containerLayoutAcknowledgement else { return false }
        return acknowledgement.token == renderToken && acknowledgement.attachment == attachmentRevision
            && acknowledgement.geometry == settledContainerLayoutGeometry()
    }

    private func settledContainerLayoutGeometry() -> ContainerLayoutGeometry? {
        guard let anchor = bridgeAnchor, anchor.window != nil, !anchor.needsLayout,
              !anchor.isHiddenOrHasHiddenAncestor, let scrollView, let documentView,
              anchor.enclosingScrollView === scrollView, scrollView.documentView === documentView else { return nil }
        let container = anchor.convert(anchor.bounds, to: documentView)
        let document = documentView.bounds
        let viewportSize = scrollView.contentView.bounds.size
        for rect in [container, document] {
            guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { return nil }
        }
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        // A scroll's own origin change does not invalidate content layout.
        return ContainerLayoutGeometry(container: container, document: document, viewportSize: viewportSize)
    }

    /// Installing a representable during a SwiftUI update does not prove its
    /// new row targets have participated in native layout. The current bridge
    /// must finish layout in this exact attachment before discovery can run.
    func renderContainerDidLayout(
        token: TranscriptRenderToken, attachment: UInt64, from anchor: NSView
    ) {
        guard token == renderToken, attachment == attachmentRevision,
              anchor === bridgeAnchor, anchor.window != nil, !anchor.needsLayout,
              !anchor.isHiddenOrHasHiddenAncestor,
              let scrollView, anchor.enclosingScrollView === scrollView,
              let documentView, scrollView.documentView === documentView else { return }
        guard let geometry = settledContainerLayoutGeometry() else { return }
        let alreadyAcknowledged = hasCurrentContainerLayout
        containerLayoutAcknowledgement = (token, attachment, geometry)
        restoreSelectionViewportAfterLayout(token: token, attachment: attachment)
        #if DEBUG
        if !alreadyAcknowledged { recordGeometry("container.layoutAcknowledged") }
        #endif
        if !alreadyAcknowledged { schedulePin() }
    }

    func tailProbesDidLayout(
        token: TranscriptRenderToken, attachment: UInt64, in scroll: NSScrollView
    ) {
        guard token == renderToken, attachment == attachmentRevision, scroll === scrollView else { return }
        // Sample both attached probes in one frame. Never combine one row's
        // new coordinates with the footer's previous lazy-layout estimate.
        let content = contentProbe?.measuredRect(token: token, in: scroll)
        let end = endProbe?.measuredRect(token: token, in: scroll)
        let predecessor = predecessorProbe?.measuredRect(token: token, in: scroll)
        let changed = content != contentRect || end != endRect || predecessor != predecessorRect
        contentRect = content
        endRect = end
        predecessorRect = predecessor
        updateNearBottom()
        if measuredTailIsAtBottom() {
            isProgrammaticScroll = false
            lastOriginY = scroll.contentView.bounds.origin.y
        } else if changed {
            schedulePin()
        }
        #if DEBUG
        recordGeometry("tail.sameFrameLayout")
        #endif
    }

    private func measuredTailIsAtBottom() -> Bool {
        guard let scrollView, let documentView, let contentRect, let endRect else { return false }
        let visible = scrollView.documentVisibleRect
        let distance = documentView.isFlipped
            ? endRect.maxY - visible.maxY : visible.minY - endRect.minY
        return contentRect.intersects(visible) && endRect.intersects(visible)
            && (abs(distance) <= 2 || measuredContentFitsViewport(visible, document: documentView, end: endRect))
    }

    /// A short conversation may end above the viewport bottom. Accept that
    /// only at the logical start, using the actual terminal content extent;
    /// a lazy document's estimated height is not evidence of a completed pin.
    private func measuredContentFitsViewport(_ visible: NSRect, document: NSView, end: NSRect) -> Bool {
        if document.isFlipped {
            return abs(visible.minY - document.bounds.minY) <= 2
                && end.maxY - document.bounds.minY <= visible.height + 2
        }
        return abs(visible.maxY - document.bounds.maxY) <= 2
            && document.bounds.maxY - end.minY <= visible.height + 2
    }

    func attach(from anchor: NSView, expectedToken: TranscriptRenderToken? = nil) {
        if let expectedToken, expectedToken != renderToken { return }
        #if DEBUG
        geometryDiagnosticAnchor = anchor
        #endif
        guard let candidate = anchor.enclosingScrollView else {
            #if DEBUG
            recordGeometry("attach.noScrollView")
            #endif
            return
        }
        if scrollView === candidate, documentView === candidate.documentView,
           bridgeAnchor === anchor,
           observerSessionGeneration == renderToken?.sessionGeneration { return }
        detachObservers()
        attachmentRevision &+= 1
        let attachment = attachmentRevision
        bridgeAnchor = anchor
        observerSessionGeneration = renderToken?.sessionGeneration
        scrollView = candidate
        documentView = candidate.documentView
        lastViewportSize = candidate.contentView.bounds.size
        contentRect = nil
        endRect = nil
        predecessorRect = nil
        realizationRequested = false
        realizationGeometry.removeAll(keepingCapacity: true)
        containerLayoutAcknowledgement = nil
        lastAlignment = nil
        candidate.contentView.postsBoundsChangedNotifications = true
        candidate.documentView?.postsFrameChangedNotifications = true
        lastOriginY = candidate.contentView.bounds.origin.y

        let center = NotificationCenter.default
        #if DEBUG
        if geometryDiagnosticsEnabled, let window = candidate.window {
            observers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.attachmentRevision == attachment else { return }
                    self.recordGeometry("window.occlusionChanged")
                }
            })
        }
        #endif
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: candidate.documentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.attachmentRevision == attachment else { return }
                self.documentFrameChanged()
            }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: candidate.contentView,
            queue: .main
        ) { [weak self] _ in
            // Reader-owned glyphs must not visibly move while a queued
            // container acknowledgement waits behind native scroll anchoring.
            // Admit only the measured selection correction synchronously;
            // ordinary observable state publication remains deferred below.
            MainActor.assumeIsolated {
                guard let self, self.attachmentRevision == attachment,
                      let token = self.renderToken else { return }
                self.restoreSelectionViewportAfterLayout(
                    token: token, attachment: attachment, publishDerivedState: false
                )
                self.restoreActivityResultAfterLayout()
            }
            Task { @MainActor [weak self] in
                guard let self, self.attachmentRevision == attachment else { return }
                self.boundsChanged()
            }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            // The observer's .main queue is the main-actor admission boundary.
            // Deferring user intent lets a pending display tick pin the old
            // bottom after the native gesture has already moved the viewport.
            MainActor.assumeIsolated {
                guard let self, self.attachmentRevision == attachment else { return }
                self.liveScrollStarted()
            }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.attachmentRevision == attachment else { return }
                self.userViewportChanged()
            }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.attachmentRevision == attachment else { return }
                self.liveScrollEnded()
            }
        })

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak candidate] event in
            guard let self, let candidate else { return event }
            guard TranscriptScrollMetrics.ownsWheelLocation(
                event.locationInWindow, eventWindow: event.window, scrollView: candidate
            ) else {
                self.isRoutingVerticalWheel = false
                return event
            }
            self.selectionViewportOwnership = nil

            if let deltaY = TranscriptScrollMetrics.dominantVerticalWheelDelta(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                legacyDeltaX: event.deltaX,
                legacyDeltaY: event.deltaY
            ) {
                self.isRoutingVerticalWheel = true
                self.wheelMoved(deltaY: deltaY)
            }
            guard self.isRoutingVerticalWheel else { return event }

            // SwiftUI can place selectable text and horizontal code views in
            // their own scroll responders. Letting those receive a vertical
            // trackpad gesture makes the transcript appear to stop at message,
            // reasoning, and tool boundaries. Route the complete gesture to
            // the transcript's native scroll view so AppKit retains precise
            // deltas, momentum, elasticity, and its normal frame pacing.
            // Horizontal-dominant gestures still reach code blocks normally.
            candidate.scrollWheel(with: event)
            let phaseEnded = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            let momentumEnded = event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
            if phaseEnded || momentumEnded
                || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                self.isRoutingVerticalWheel = false
            }
            return nil
        }
        #if DEBUG
        recordGeometry("attach.ready")
        #endif
        updateNearBottom()
        anchor.needsLayout = true
        contentProbe?.requestObservation()
        endProbe?.requestObservation()
        predecessorProbe?.requestObservation()
        contentMayHaveChanged()
    }

    func contentMayHaveChanged() {
        #if DEBUG
        recordGeometry("content.changed")
        #endif
        let revision = scrollIntentRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollIntentRevision == revision else { return }
            if self.followState.permitsAutomaticScroll {
                self.schedulePin()
            } else {
                self.updateNearBottom()
            }
        }
    }

    func detach() {
        activityResultOwnership = nil
        selectionViewportOwnership = nil
        readerIntentRevision &+= 1
        scrollIntentRevision &+= 1
        isProgrammaticScroll = false
        pinPending = false
        displayLink?.isPaused = true
        lastAlignment = nil
        mutateState { $0.detach() }
    }

    func beginActivityResultReveal(_ id: UUID) {
        detach()
        guard let token = renderToken else { return }
        activityResultOwnership = (id, token.sessionGeneration, readerIntentRevision)
        activityResultProbe?.requestObservation()
    }

    func finishActivityResultReveal(_ id: UUID) {
        guard activityResultOwnership?.id == id else { return }
        activityResultOwnership = nil
    }

    func registerActivityResultProbe(_ probe: TranscriptTailLayoutView) {
        activityResultProbe = probe
    }

    func unregisterActivityResultProbe(_ probe: TranscriptTailLayoutView) {
        if activityResultProbe === probe { activityResultProbe = nil }
    }

    func activityResultDidLayout(_ probe: TranscriptTailLayoutView, attachment: UInt64) {
        guard probe === activityResultProbe, attachment == attachmentRevision else { return }
        restoreActivityResultAfterLayout()
    }

    private func restoreActivityResultAfterLayout() {
        guard !isRestoringActivityResult, let ownership = activityResultOwnership,
              let token = renderToken, ownership.generation == token.sessionGeneration,
              ownership.readerRevision == readerIntentRevision,
              !isUserLiveScrolling, !isSelectionDragActive,
              let probe = activityResultProbe, probe.activityRevealID == ownership.id,
              let scrollView, let documentView,
              let rect = probe.measuredRect(token: token, in: scrollView) else { return }
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin.y = documentView.isFlipped
            ? rect.minY - 12 : rect.maxY - clip.bounds.height + 12
        let target = clip.constrainBoundsRect(proposed).origin
        guard target.y.isFinite, abs(target.y - clip.bounds.origin.y) > 1 else { return }
        isRestoringActivityResult = true
        defer { isRestoringActivityResult = false }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        lastOriginY = clip.bounds.origin.y
    }

    /// Selection gives the reader control of the viewport. Releasing the
    /// pointer does not give that control back to streaming output; only an
    /// explicit send or Jump to Latest re-engages following.
    func setSelectionDragActive(_ active: Bool) {
        guard isSelectionDragActive != active else { return }
        isSelectionDragActive = active
        if active {
            detach()
        } else {
            updateNearBottom()
        }
    }

    /// Capture only at an actual selection gesture. A completed nonempty
    /// selection keeps this ownership; layout/registration cannot re-arm it
    /// after newer reader input, a removed leaf, or a conversation switch.
    func setSelectionViewportAnchor(_ anchor: TranscriptSelectionViewportAnchor?) {
        guard let anchor, let token = renderToken, let scrollView,
              let glyph = anchor.measuredGlyph(in: scrollView) else {
            selectionViewportOwnership = nil
            return
        }
        detach()
        selectionViewportOwnership = SelectionViewportOwnership(
            anchor: anchor, generation: token.sessionGeneration,
            attachment: attachmentRevision, readerRevision: readerIntentRevision,
            glyphOffsetY: glyph.minY - scrollView.contentView.bounds.minY
        )
    }

    private func restoreSelectionViewportAfterLayout(
        token: TranscriptRenderToken, attachment: UInt64, publishDerivedState: Bool = true
    ) {
        guard !isRestoringSelectionViewport else { return }
        guard var ownership = selectionViewportOwnership,
              ownership.generation == token.sessionGeneration,
              ownership.attachment == attachment, ownership.readerRevision == readerIntentRevision,
              !followState.permitsAutomaticScroll, !isUserLiveScrolling,
              let scrollView, let documentView else {
            selectionViewportOwnership = nil
            return
        }
        let glyph: NSRect
        switch ownership.anchor.measureGlyph(in: scrollView) {
        case .invalid:
            selectionViewportOwnership = nil
            return
        case .awaitingLayout:
            // Keep only this still-valid lease until another authenticated
            // native layout observation; never poll or publish a new anchor.
            return
        case let .measured(rect):
            glyph = rect
        }
        let clip = scrollView.contentView
        let geometry = SelectionLayoutGeometry(
            token: token, glyph: glyph, document: documentView.bounds, viewportSize: clip.bounds.size
        )
        // A framework-origin change is not new layout evidence. At most one
        // correction per actual glyph/document/token geometry prevents an
        // origin-notification feedback loop with native scroll anchoring.
        guard ownership.lastRestoredGeometry != geometry else { return }
        var proposed = clip.bounds
        proposed.origin.y = glyph.minY - ownership.glyphOffsetY
        let target = clip.constrainBoundsRect(proposed).origin
        guard target.y.isFinite, target != clip.bounds.origin else { return }
        ownership.lastRestoredGeometry = geometry
        selectionViewportOwnership = ownership
        isRestoringSelectionViewport = true
        defer { isRestoringSelectionViewport = false }
        #if DEBUG
        recordGeometry("selection.restoreMeasuredGlyph", target: target)
        #endif
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        lastOriginY = clip.bounds.origin.y
        if publishDerivedState { updateNearBottom() }
    }

    func jumpToLatest(animated: Bool = false) {
        activityResultOwnership = nil
        selectionViewportOwnership = nil
        readerIntentRevision &+= 1
        mutateState { $0.jumpToLatest() }
        pinPending = false
        displayLink?.isPaused = true
        lastAlignment = nil
        realizationRequested = false
        realizationGeometry.removeAll(keepingCapacity: true)
        if animated {
            scrollToBottom(animated: true)
        } else {
            schedulePin()
        }
    }

    func resetForSession() {
        activityResultOwnership = nil
        selectionViewportOwnership = nil
        pendingSessionFollowReset = nil
        scrollIntentRevision &+= 1
        isProgrammaticScroll = false
        pinPending = false
        displayLink?.isPaused = true
        isUserLiveScrolling = false
        isSelectionDragActive = false
        isRoutingVerticalWheel = false
        contentRect = nil
        endRect = nil
        predecessorRect = nil
        realizationRequested = false
        realizationGeometry.removeAll(keepingCapacity: true)
        lastAlignment = nil
        mutateState { $0 = TranscriptFollowState() }
        contentMayHaveChanged()
    }

    func detachAll() {
        activityResultOwnership = nil
        activityResultProbe = nil
        #if DEBUG
        recordGeometry("detachAll")
        #endif
        isRoutingVerticalWheel = false
        detachObservers()
        scrollView = nil
        documentView = nil
        scrollToBottomTarget = nil
        realizeTailTarget = nil
        realizePredecessorTarget = nil
        pendingSessionFollowReset = nil
        pendingSessionViewportReset = nil
        bridgeAnchor = nil
        contentRect = nil
        endRect = nil
        predecessorRect = nil
        lastAlignment = nil
    }

    func detach(from anchor: NSView) {
        guard bridgeAnchor === anchor else { return }
        detachAll()
    }

    private func wheelMoved(deltaY: CGFloat) {
        activityResultOwnership = nil
        selectionViewportOwnership = nil
        updateNearBottom()
        if deltaY > 0 {
            detach()
        } else {
            mutateState { $0.userScrolled(upward: false) }
        }
    }

    private func liveScrollStarted() {
        activityResultOwnership = nil
        selectionViewportOwnership = nil
        readerIntentRevision &+= 1
        scrollIntentRevision &+= 1
        isProgrammaticScroll = false
        isUserLiveScrolling = true
        pinPending = false
        displayLink?.isPaused = true
        lastOriginY = scrollView?.contentView.bounds.origin.y ?? lastOriginY
    }

    private func liveScrollEnded() {
        userViewportChanged()
        isUserLiveScrolling = false
    }

    private func userViewportChanged() {
        guard let scrollView, !isProgrammaticScroll else { return }
        let origin = scrollView.contentView.bounds.origin.y
        let movedTowardBottom = documentView?.isFlipped == false
            ? origin < lastOriginY
            : origin > lastOriginY
        lastOriginY = origin
        updateNearBottom()
        if movedTowardBottom, followState.isNearBottom {
            mutateState { $0.userScrolled(upward: false) }
        } else if !movedTowardBottom {
            detach()
        }
    }

    private func boundsChanged() {
        guard let scrollView else { return }
        #if DEBUG
        recordGeometry("bounds.changed")
        #endif
        let origin = scrollView.contentView.bounds.origin.y
        let viewport = scrollView.contentView.bounds.size
        if viewport != lastViewportSize {
            if viewport.width != lastViewportSize.width {
                contentRect = nil
                endRect = nil
                predecessorRect = nil
                realizationRequested = false
                realizationGeometry.removeAll(keepingCapacity: true)
                contentProbe?.requestObservation()
                endProbe?.requestObservation()
                predecessorProbe?.requestObservation()
            }
            lastViewportSize = viewport
            lastAlignment = nil
            schedulePin()
        }
        if isProgrammaticScroll {
            lastOriginY = origin
            updateNearBottom()
            if measuredTailIsAtBottom() { isProgrammaticScroll = false }
            else { schedulePin() }
        } else if isUserLiveScrolling {
            userViewportChanged()
        } else {
            lastOriginY = origin
            updateNearBottom()
        }
    }

    private func documentFrameChanged() {
        #if DEBUG
        recordGeometry("document.frameChanged")
        #endif
        if followState.permitsAutomaticScroll, !isSelectionDragActive {
            schedulePin()
        } else {
            updateNearBottom()
        }
    }

    private func updateNearBottom() {
        guard let scrollView, let documentView else { return }
        if let token = renderToken {
            let visible = scrollView.documentVisibleRect
            let isNear: Bool
            if token.tailID == nil {
                isNear = true
            } else if let contentRect, let endRect {
                let distance = documentView.isFlipped
                    ? endRect.maxY - visible.maxY : visible.minY - endRect.minY
                isNear = contentRect.intersects(visible) && endRect.intersects(visible)
                    && (abs(distance) <= 24
                        || measuredContentFitsViewport(visible, document: documentView, end: endRect))
            } else {
                isNear = false
            }
            mutateState { $0.updateBottom(isNear: isNear) }
            return
        }
        let distance = TranscriptScrollMetrics.bottomDistance(
            documentBounds: documentView.bounds,
            visibleRect: scrollView.documentVisibleRect,
            isFlipped: documentView.isFlipped
        )
        mutateState { $0.updateBottom(isNear: distance <= 24) }
    }

    private func schedulePin() {
        guard followState.permitsAutomaticScroll, !isSelectionDragActive,
              !isUserLiveScrolling,
              (renderToken != nil || scrollToBottomTarget != nil), let scrollView
        else { return }
        pinPending = true
        if displayLink == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        #if DEBUG
        geometryDiagnosticDisplayTicks += 1
        if geometryDiagnosticDisplayTicks <= 12 { recordGeometry("display.tick") }
        #endif
        guard pinPending, followState.permitsAutomaticScroll,
              !isSelectionDragActive, !isUserLiveScrolling else {
            link.isPaused = true
            return
        }
        pinPending = false
        link.isPaused = true
        scrollToBottom(animated: false)
    }

    private func scrollToBottom(animated: Bool) {
        guard followState.permitsAutomaticScroll, !isSelectionDragActive,
              !isUserLiveScrolling, let scrollView
        else { return }
        if let token = renderToken {
            advanceMeasuredPin(token: token, animated: animated)
            return
        }
        guard let scrollToBottomTarget else { return }
        let revision = scrollIntentRevision
        pinCompletionRevision &+= 1
        let pinRevision = pinCompletionRevision
        #if DEBUG
        recordGeometry("bottom.before")
        #endif
        isProgrammaticScroll = true
        let finish: @MainActor @Sendable () -> Void = { [weak self, weak scrollView] in
            guard let self, self.scrollIntentRevision == revision,
                  self.pinCompletionRevision == pinRevision,
                  self.scrollView === scrollView else { return }
            if let scrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.lastOriginY = scrollView.contentView.bounds.origin.y
            }
            self.isProgrammaticScroll = false
            self.updateNearBottom()
            #if DEBUG
            self.recordGeometry("bottom.after")
            #endif
        }
        if animated {
            withAnimation(LocusMotion.scroll, completionCriteria: .logicallyComplete) {
                scrollToBottomTarget()
            } completion: {
                DispatchQueue.main.async(execute: finish)
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollToBottomTarget() }
            // The logical target resolves during SwiftUI's following layout,
            // not synchronously while the proxy receives the request.
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func advanceMeasuredPin(token: TranscriptRenderToken, animated: Bool) {
        guard token.tailID != nil, let scrollView else { return }
        if measuredTailIsAtBottom() {
            pendingSessionViewportReset = nil
            isProgrammaticScroll = false
            updateNearBottom()
            return
        }
        if contentRect == nil || endRect == nil {
            guard hasCurrentContainerLayout, let layout = containerLayoutAcknowledgement?.geometry else {
                // An attempted discovery observed stale or unfinished layout.
                // Its next real native acknowledgment must be able to resume
                // the pending request even if the final size is unchanged.
                containerLayoutAcknowledgement = nil
                return
            }
            if pendingSessionViewportReset == token.sessionGeneration {
                pendingSessionViewportReset = nil
                if resetReplacedSessionViewport() { return }
            }
            guard let realizeTailTarget else { return }
            let viewport = scrollView.contentView.bounds
            // A predecessor request can change the lazy estimate before its
            // actual row is laid out. Do not follow that estimate with another
            // proxy jump. Sample the exact registered native row now, in this
            // attachment's settled layout, rather than reuse its cached rect.
            let predecessor = realizePredecessorTarget == nil ? nil
                : predecessorProbe?.measuredRect(token: token, in: scrollView)
            if realizePredecessorTarget != nil, predecessor == nil, realizationRequested { return }
            let adjacentTarget: NSPoint?
            if let predecessor, let documentView {
                guard predecessor.minY.isFinite, predecessor.maxY.isFinite else { return }
                var proposed = viewport
                proposed.origin.y = documentView.isFlipped
                    ? predecessor.maxY : predecessor.minY - viewport.height
                let target = scrollView.contentView.constrainBoundsRect(proposed).origin
                guard target.y.isFinite else { return }
                realizationRequested = true
                guard target != viewport.origin else { return }
                adjacentTarget = target
            } else {
                adjacentTarget = nil
            }
            // A logical request can first update the lazy estimate without
            // realizing the row. Only new native geometry may advance that
            // request. Remember every observed geometry, not just the last,
            // so a repeated/oscillating estimate cannot create a scroll loop.
            guard !realizationGeometry.contains(where: {
                $0.layout == layout && $0.viewport == viewport && $0.predecessor == predecessor
            }), realizationGeometry.count < 32 else { return }
            realizationGeometry.append((layout, viewport, predecessor))
            realizationRequested = true
            isProgrammaticScroll = true
            if let adjacentTarget {
                // The next semantic row begins at the predecessor's measured
                // boundary. Expose that boundary using real native geometry;
                // only actual terminal probes can subsequently finish the pin.
                #if DEBUG
                recordGeometry("predecessor.alignNativeBoundary", target: adjacentTarget)
                #endif
                scrollView.contentView.scroll(to: adjacentTarget)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                return
            }
            #if DEBUG
            recordGeometry(realizePredecessorTarget != nil ? "predecessor.requestRealization" : "tail.requestRealization")
            #endif
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let realizePredecessorTarget { realizePredecessorTarget() } else { realizeTailTarget() }
            }
            return
        }
        guard let endRect, let documentView else { return }
        let viewport = scrollView.contentView.bounds
        let document = documentView.bounds
        if let previous = lastAlignment, previous.token == token,
           previous.end == endRect, previous.viewport == viewport,
           previous.document == document { return }
        lastAlignment = (token, endRect, viewport, document)
        isProgrammaticScroll = true
        #if DEBUG
        recordGeometry("tail.alignMeasuredEnd")
        #endif
        if let scrollToBottomTarget {
            // An injected logical driver can be used by native coordinator
            // fixtures; production aligns the actual measured coordinates.
            scrollToBottomTarget()
        } else {
            let clip = scrollView.contentView
            var proposed = clip.bounds
            proposed.origin.y = documentView.isFlipped
                ? endRect.maxY - proposed.height : endRect.minY
            let target = clip.constrainBoundsRect(proposed).origin
            #if DEBUG
            recordGeometry("tail.alignNativeEnd", target: target)
            #endif
            // Apply one exact native alignment in this display refresh.
            // An animator would continue changing bounds after reader input
            // or a conversation change, outside this operation's token.
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        // Only bounds/layout observations can acknowledge completion. A
        // queued closure or animation completion is not evidence of visibility.
    }

    /// An old conversation's offset is not a position in the replacement.
    /// When its new rows have not been realized, establish the document's
    /// actual logical start before resolving its terminal row. This runs at
    /// most once per genuine switch, never on append, streaming or rekey.
    private func resetReplacedSessionViewport() -> Bool {
        guard let scrollView, let documentView, let bridgeAnchor else { return false }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = documentView.isFlipped ? documentView.bounds.minY
            : max(documentView.bounds.minY, documentView.bounds.maxY - clip.bounds.height)
        guard origin != clip.bounds.origin else { return false }
        isProgrammaticScroll = true
        containerLayoutAcknowledgement = nil
        #if DEBUG
        recordGeometry("session.resetLogicalStart", target: origin)
        #endif
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        lastOriginY = clip.bounds.origin.y
        // Discovery waits for this exact attachment's native layout; a
        // queued callback alone cannot acknowledge the new viewport.
        bridgeAnchor.needsLayout = true
        return true
    }

    private func mutateState(_ mutation: (inout TranscriptFollowState) -> Void) {
        var next = followState
        mutation(&next)
        if next != followState { followState = next }
    }

    private func detachObservers() {
        selectionViewportOwnership = nil
        attachmentRevision &+= 1
        containerLayoutAcknowledgement = nil
        scrollIntentRevision &+= 1
        isProgrammaticScroll = false
        isUserLiveScrolling = false
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        displayLink?.invalidate()
        displayLink = nil
        pinPending = false
        isRoutingVerticalWheel = false
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        displayLink?.invalidate()
    }
}

private struct TranscriptScrollBridge: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator
    #if DEBUG
    let diagnosticItemCount: Int
    #endif
    let token: TranscriptRenderToken
    let realizeTail: () -> Void
    let realizePredecessor: (() -> Void)?

    func makeNSView(context: Context) -> TranscriptScrollAnchorView {
        let view = TranscriptScrollAnchorView(frame: .zero)
        guard coordinator.installRenderTarget(
            token, realizeTail: realizeTail, realizePredecessor: realizePredecessor
        ) else { return view }
        #if DEBUG
        coordinator.setDiagnosticItemCount(diagnosticItemCount)
        #endif
        view.transcriptCoordinator = coordinator
        view.renderToken = token
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, view.window != nil,
                  view.transcriptCoordinator === coordinator, view.renderToken == token else { return }
            coordinator.attach(from: view, expectedToken: token)
        }
        return view
    }

    func updateNSView(_ view: TranscriptScrollAnchorView, context: Context) {
        guard coordinator.installRenderTarget(
            token, realizeTail: realizeTail, realizePredecessor: realizePredecessor
        ) else { return }
        let needsCurrentLayout = view.renderToken != token
        #if DEBUG
        coordinator.setDiagnosticItemCount(diagnosticItemCount)
        #endif
        view.transcriptCoordinator = coordinator
        view.renderToken = token
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator, view.window != nil,
                  view.transcriptCoordinator === coordinator, view.renderToken == token else { return }
            coordinator.attach(from: view, expectedToken: token)
            // Do not invalidate native layout from inside SwiftUI's graph
            // update. The token must first finish installing its row targets.
            if needsCurrentLayout { view.needsLayout = true }
        }
    }

    static func dismantleNSView(_ nsView: TranscriptScrollAnchorView, coordinator: ()) {
        nsView.transcriptCoordinator?.detach(from: nsView)
        nsView.transcriptCoordinator = nil
        nsView.renderToken = nil
    }
}

private final class TranscriptScrollAnchorView: NSView {
    weak var transcriptCoordinator: TranscriptScrollCoordinator?
    var renderToken: TranscriptRenderToken?
    private var observationRevision: UInt64 = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    override func layout() {
        super.layout()
        guard let token = renderToken, let coordinator = transcriptCoordinator,
              window != nil, let scroll = enclosingScrollView,
              let document = scroll.documentView else { return }
        let attachment = coordinator.layoutAttachmentRevision
        let rect = convert(bounds, to: document)
        observationRevision &+= 1
        let revision = observationRevision
        DispatchQueue.main.async { [weak self, weak coordinator, weak scroll, weak document] in
            guard let self, let coordinator, let scroll, let document,
                  self.renderToken == token, self.observationRevision == revision,
                  self.transcriptCoordinator === coordinator, self.window != nil,
                  self.enclosingScrollView === scroll, scroll.documentView === document,
                  !self.needsLayout else { return }
            guard self.convert(self.bounds, to: document) == rect else {
                self.needsLayout = true
                return
            }
            coordinator.renderContainerDidLayout(token: token, attachment: attachment, from: self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The async hop lets SwiftUI finish inserting this view into the
        // scroll view's document hierarchy before the coordinator resolves
        // `enclosingScrollView`.
        let token = renderToken
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.renderToken == token else { return }
            self.transcriptCoordinator?.attach(from: self, expectedToken: token)
        }
    }
}

/// A marker laid out with real terminal content, rather than with the lazy
/// document's estimated total extent. It never measures or logs message text.
private struct TranscriptTailLayoutProbe: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator
    let token: TranscriptRenderToken
    let kind: TranscriptTailLayoutKind

    func makeNSView(context: Context) -> TranscriptTailLayoutView {
        let view = TranscriptTailLayoutView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: TranscriptTailLayoutView, context: Context) { configure(view) }

    private func configure(_ view: TranscriptTailLayoutView) {
        view.transcriptCoordinator = coordinator
        view.token = token
        view.kind = kind
        coordinator.registerTailProbe(view)
        view.requestObservation()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TranscriptTailLayoutView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: TranscriptTailLayoutView, coordinator: ()) {
        view.transcriptCoordinator?.unregisterTailProbe(view)
        view.transcriptCoordinator = nil
        view.token = nil
    }
}

private struct TranscriptActivityResultProbe: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator
    let token: TranscriptRenderToken
    let requestID: UUID

    func makeNSView(context: Context) -> TranscriptTailLayoutView {
        let view = TranscriptTailLayoutView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: TranscriptTailLayoutView, context: Context) { configure(view) }

    private func configure(_ view: TranscriptTailLayoutView) {
        view.transcriptCoordinator = coordinator
        view.token = token
        view.activityRevealID = requestID
        coordinator.registerActivityResultProbe(view)
        view.requestObservation()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTailLayoutView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: TranscriptTailLayoutView, coordinator: ()) {
        view.transcriptCoordinator?.unregisterActivityResultProbe(view)
        view.transcriptCoordinator = nil
        view.token = nil
    }
}

final class TranscriptTailLayoutView: NSView {
    weak var transcriptCoordinator: TranscriptScrollCoordinator?
    var token: TranscriptRenderToken?
    var kind: TranscriptTailLayoutKind = .content
    var activityRevealID: UUID?
    private var observationRevision: UInt64 = 0
    private var ancestorObservers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    func requestObservation() { needsLayout = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeAncestorLayout()
        if window != nil { requestObservation() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeAncestorLayout()
        requestObservation()
    }

    private func observeAncestorLayout() {
        ancestorObservers.forEach(NotificationCenter.default.removeObserver)
        ancestorObservers.removeAll()
        guard window != nil else { return }
        var ancestor = superview
        var depth = 0
        while let view = ancestor, !(view is NSClipView), depth < 32 {
            view.postsFrameChangedNotifications = true
            ancestorObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestObservation() }
            })
            ancestor = view.superview
            depth += 1
        }
    }

    func measuredRect(token: TranscriptRenderToken, in scroll: NSScrollView) -> NSRect? {
        guard self.token == token, window != nil, !needsLayout,
              !isHiddenOrHasHiddenAncestor, enclosingScrollView === scroll,
              let document = scroll.documentView else { return nil }
        let rect = convert(bounds, to: document)
        return rect.isEmpty ? nil : rect
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestObservation()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        requestObservation()
    }

    override func layout() {
        super.layout()
        guard let token, let coordinator = transcriptCoordinator, window != nil,
              !isHiddenOrHasHiddenAncestor, let scroll = enclosingScrollView,
              let document = scroll.documentView else { return }
        let rect = convert(bounds, to: document)
        let attachment = coordinator.layoutAttachmentRevision
        observationRevision &+= 1
        let revision = observationRevision
        DispatchQueue.main.async { [weak self, weak coordinator, weak scroll, weak document] in
            guard let self, let coordinator, let scroll, let document,
                  self.window != nil, self.token == token,
                  self.observationRevision == revision,
                  self.transcriptCoordinator === coordinator,
                  self.enclosingScrollView === scroll, scroll.documentView === document else { return }
            guard self.convert(self.bounds, to: document) == rect else {
                // New ancestor geometry is new evidence, not a polling timer.
                self.requestObservation()
                return
            }
            if self.activityRevealID != nil {
                coordinator.activityResultDidLayout(self, attachment: attachment)
            } else {
                coordinator.tailProbesDidLayout(token: token, attachment: attachment, in: scroll)
            }
        }
    }

    deinit { ancestorObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// ⌘F search over the current conversation. Matches whole blocks (tool cards
/// excluded); ↵ and ⇧↵ walk matches with wrap-around, esc closes.
private struct TranscriptSearchBar: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var countText: String {
        let matches = model.transcriptSearchMatches
        if matches.isEmpty {
            return model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "0 results"
        }
        let current = min(max(model.transcriptSearchSelection, 0), matches.count - 1)
        return "\(current + 1) of \(matches.count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(viewColors.muted)

            TextField("Find in conversation", text: $model.transcriptSearchQuery)
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .focused($focused)
                .accessibilityIdentifier("search.field")
                .onKeyPress(keys: [.return]) { press in
                    model.advanceTranscriptSearch(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.closeTranscriptSearch()
                    return .handled
                }

            if !countText.isEmpty {
                Text(countText)
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(viewColors.muted)
                    .accessibilityIdentifier("search.count")
            }

            Button {
                model.advanceTranscriptSearch(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .foregroundStyle(viewColors.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Previous match (⇧↵)")
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("search.prev")

            Button {
                model.advanceTranscriptSearch(1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .foregroundStyle(viewColors.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Next match (↵)")
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("search.next")

            Button {
                model.closeTranscriptSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .foregroundStyle(viewColors.muted)
            .help("Close search (esc)")
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("search.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(viewColors.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
        .onAppear { focused = true }
    }
}

private struct EmptyConversationView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            BrandMark(accent: model.effectiveAccent, compact: true)
                .padding(.bottom, 6)

            Text("How can Locus help?")
                .font(.locus(size: 26, weight: .medium))
                .tracking(-0.7)
                .foregroundStyle(viewColors.ink)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("conversation.welcome.title")

            Text("Ask a question or describe what you’d like Locus to do.")
                .font(.locus(size: 11))
                .foregroundStyle(viewColors.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("conversation.welcome.prompt")

            if activeRuntimePhase != .online {
                Label(runtimeStatus, systemImage: "circle.fill")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(runtimeColor)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 88)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Locus")
        .accessibilityIdentifier("conversation.welcome")
    }

    private var activeRuntimePhase: RuntimePhase {
        model.isAgentOnline ? model.modelRuntimePhase : model.agentRuntimePhase
    }

    private var runtimeColor: Color {
        switch activeRuntimePhase {
        case .starting, .recovering: viewColors.warning
        case .online: viewColors.success
        case .unavailable: viewColors.coral
        }
    }

    private var runtimeStatus: String {
        switch activeRuntimePhase {
        case .starting: "Local services are starting"
        case .online: "Local services are ready"
        case .recovering: "Local services are recovering"
        case .unavailable: "Local services need attention"
        }
    }
}

/// An immutable transcript row. Keeping the observable AppModel out of this
/// view is what prevents a token publication for the active reply from
/// invalidating every completed Markdown row above it.
private struct ActiveAssistantBlockView: View {
    @ObservedObject var reply: StreamingReplyState
    var frozenSnapshot: StreamingReplySnapshot? = nil
    let thinkingVisibility: ThinkingVisibility
    let accent: LocusAccentSelection
    let workspacePath: String
    let showsMarker: Bool
    let isReasoningActivity: Bool
    let selectionStore: TranscriptSelectionStore
    let selectionRowID: String
    let onOpenWorkspaceReference: (WorkspaceArtifactReference) -> Void

    @ViewBuilder
    var body: some View {
        if isReasoningActivity {
            StreamingMessageContentView(
                reply: reply,
                snapshotOverride: frozenSnapshot,
                thinkingVisibility: thinkingVisibility,
                workspacePath: workspacePath,
                activityOnly: true,
                activityMarkerAccent: showsMarker ? accent : nil,
                selectionStore: selectionStore,
                selectionRowID: selectionRowID,
                onOpenWorkspaceReference: onOpenWorkspaceReference
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("message.streamingAssistant")
        } else {
            HStack(alignment: .top, spacing: 10) {
                assistantMarker
                StreamingMessageContentView(
                    reply: reply,
                    snapshotOverride: frozenSnapshot,
                    thinkingVisibility: thinkingVisibility,
                    workspacePath: workspacePath,
                    selectionStore: selectionStore,
                    selectionRowID: selectionRowID,
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("message.streamingAssistant")
        }
    }

    @ViewBuilder
    private var assistantMarker: some View {
        if showsMarker {
            LocusMessageMarker(accent: accent)
                .accessibilityIdentifier("message.streamingAssistant.marker")
        } else {
            Color.clear
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}

struct LocusMessageMarker: View {
    let accent: LocusAccentSelection

    private var fill: Color { accent.fillColor }
    private var action: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            accent.actionNSColor(for: appearance)
        })
    }
    private var ink: Color { Color(nsColor: accent.brandInkNSColor()) }

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fill)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: "sparkle")
                    .font(.locus(size: 9, weight: .bold))
                    .foregroundStyle(ink)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(action.opacity(0.4), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct IncomingEventTranscriptCard: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    let context: EventTranscriptContext

    private var actor: String {
        context.event.actor["email"]?.string
            ?? context.event.actor["username"]?.string
            ?? context.event.actor["name"]?.string
            ?? context.event.actor["id"]?.string
            ?? "Unknown sender"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(context.source.title, systemImage: context.source.symbol)
                    .font(.locus(size: 10, weight: .bold))
                Spacer()
                Text("AUTOMATION EVENT")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(viewColors.signalDeep)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("TRUSTED INSTRUCTION")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(viewColors.signalDeep)
                Text(context.instruction)
                    .font(.locus(size: 9, weight: .medium))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(viewColors.signal.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("UNTRUSTED EVENT DATA")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(viewColors.warning)
                Text(context.event.subject.isEmpty
                    ? context.event.eventType : context.event.subject)
                    .font(.locus(size: 11, weight: .bold))
                Text("From \(actor)")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(viewColors.muted)
                if !context.event.text.isEmpty {
                    Text(context.event.text)
                        .font(.locus(size: 9))
                        .lineLimit(12)
                }
                HStack(spacing: 10) {
                    if !context.event.labels.isEmpty {
                        Label(context.event.labels.joined(separator: ", "), systemImage: "tag")
                    }
                    if !context.event.attachments.isEmpty {
                        Label(
                            "\(context.event.attachments.count) attachment\(context.event.attachments.count == 1 ? "" : "s")",
                            systemImage: "paperclip"
                        )
                    }
                }
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(viewColors.muted)
            }
            Text("Normal chat permissions still apply · source event \(context.sourceEventID)")
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(viewColors.muted)
            Button("View event") { model.inspectAgentEvent(context) }
                .buttonStyle(.locus())
                .font(.locus(size: 12, weight: .medium))
                .accessibilityIdentifier("eventTranscript.\(context.deliveryID).details")
        }
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(viewColors.paperDeep.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(viewColors.signalDeep.opacity(0.28), lineWidth: 1)
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("eventTranscript.\(context.deliveryID)")
    }
}

/// Gives user prompts a stable trailing measure at every window width. A fixed
/// leading spacer only approximates this relationship and lets compact windows
/// grow the prompt well beyond the intended reading-column proportion.
private struct TrailingFractionLayout: Layout {
    let maximumFraction: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let childProposal = ProposedViewSize(
            width: proposal.width.map { $0 * maximumFraction },
            height: proposal.height
        )
        let childSize = subview.sizeThatFits(childProposal)
        return CGSize(
            width: proposal.width ?? childSize.width,
            height: childSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let childProposal = ProposedViewSize(
            width: bounds.width * maximumFraction,
            height: proposal.height
        )
        let childSize = subview.sizeThatFits(childProposal)
        subview.place(
            at: CGPoint(x: bounds.maxX - childSize.width, y: bounds.minY),
            anchor: .topLeading,
            proposal: childProposal
        )
    }
}

struct MessageBlockView: View, Equatable {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var responseCopied = false
    @State private var progressExpanded = false
    @FocusState private var actionsFocused: Bool
    let block: ChatBlock
    let thinkingVisibility: ThinkingVisibility
    let accent: LocusAccentSelection
    let workspacePath: String
    let actionsDisabled: Bool
    let canRewind: Bool
    let canRegenerate: Bool
    let showsAssistantMarker: Bool
    let showsAssistantActions: Bool
    let accessibilityIdentifier: String
    let selectionStore: TranscriptSelectionStore
    let selectionRowID: String
    let onCopy: (ResponseCopyFormat) -> Void
    let onUseAsDraft: () -> Void
    let onMakeReusableCheck: () -> Void
    let onRewind: () -> Void
    let onRegenerate: () -> Void
    let onOpenWorkspaceReference: (WorkspaceArtifactReference) -> Void
    var showsConversationActions = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.thinkingVisibility == rhs.thinkingVisibility
            && lhs.accent == rhs.accent
            && lhs.workspacePath == rhs.workspacePath
            && lhs.actionsDisabled == rhs.actionsDisabled
            && lhs.canRewind == rhs.canRewind
            && lhs.canRegenerate == rhs.canRegenerate
            && lhs.showsAssistantMarker == rhs.showsAssistantMarker
            && lhs.showsAssistantActions == rhs.showsAssistantActions
            && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
            && lhs.showsConversationActions == rhs.showsConversationActions
            // The store is a stable reference and deliberately not compared;
            // the row identity it is keyed by must be.
            && lhs.selectionRowID == rhs.selectionRowID
    }

    var body: some View {
        Group {
            switch block.kind {
            case .user:
                TrailingFractionLayout(maximumFraction: 0.81) {
                    VStack(alignment: .trailing, spacing: 4) {
                        if let eventTrigger = block.eventTrigger {
                            IncomingEventTranscriptCard(context: eventTrigger)
                        } else {
                            MarkdownBodyView(
                                text: block.text,
                                workspacePath: workspacePath,
                                selectionStore: selectionStore,
                                selectionRootPath: [0],
                                selectionRowID: selectionRowID,
                                onOpenWorkspaceReference: onOpenWorkspaceReference
                            )
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(viewColors.paperDeep.opacity(0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(viewColors.line.opacity(0.7), lineWidth: 1)
                                    // A shape in an overlay takes mouse events
                                    // by default, and this one covers the whole
                                    // bubble: clicks fell through but drags did
                                    // not, so a user message could be
                                    // double-clicked and never dragged across.
                                    .allowsHitTesting(false)
                            }
                            // The bubble owns decoration; its native text
                            // children keep their own selection and hit targets.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("message.\(block.id.uuidString).bubble")
                        }
                        messageActionBar(name: "You")
                    }
                    .frame(maxWidth: 620, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

            case .assistant:
                HStack(alignment: .top, spacing: 10) {
                    assistantMarker
                    VStack(alignment: .leading, spacing: 5) {
                    if block.text.isEmpty,
                       (block.reasoningText?.isEmpty ?? true),
                       block.isStreaming
                    {
                        ThinkingDots()
                    } else {
                        if block.assistantPhase == .commentary && !block.isStreaming {
                            Button {
                                withAnimation(reduceMotion ? nil : LocusMotion.content) {
                                    progressExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .font(.locus(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(progressExpanded ? 90 : 0))
                                        .accessibilityHidden(true)
                                    Text("Progress update")
                                    Spacer(minLength: 0)
                                }
                                .font(.locus(size: 12))
                                .foregroundStyle(viewColors.muted)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.locus())
                            .accessibilityLabel("Progress update")
                            .accessibilityValue(progressExpanded ? "Expanded" : "Collapsed")
                            .accessibilityIdentifier("message.progressUpdate")
                            if progressExpanded { assistantResponse }
                        } else { assistantResponse }
                        if block.isStreaming {
                            StreamingCaret()
                        }
                    }
                        if showsAssistantActions {
                            messageActionBar(name: "Locus")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .tool:
                if let tool = block.tool {
                    ToolCardView(tool: tool)
                        .padding(.leading, 27)
                }

            case .note:
                if let completion = block.completion {
                    TurnCompletionMarker(completion: completion)
                } else {
                    Label(block.text, systemImage: "info.circle")
                        .font(.locus(size: 10, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(viewColors.paperDeep.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            case .error:
                Label(block.text, systemImage: "xmark.octagon.fill")
                    .font(.locus(size: 10, weight: .medium))
                    .foregroundStyle(viewColors.coral)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(viewColors.coral.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(viewColors.coral.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LocusMotion.press, value: isHovering || actionsFocused)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .contextMenu {
            if block.kind == .user || (block.kind == .assistant && showsAssistantActions) {
                Button("Copy Message") { onCopy(.plainText) }
                if block.kind == .assistant {
                    Button("Copy as Markdown") { onCopy(.markdown) }
                }
                Button("Use as Draft", action: onUseAsDraft)
                    .disabled(actionsDisabled)
            }
            if block.kind == .user {
                Button("Rewind to This Message", action: onRewind)
                    .disabled(!canRewind)
            }
            if canRegenerate {
                Divider()
                Button("Regenerate Response", action: onRegenerate)
            }
        }
    }

    @ViewBuilder
    private var assistantMarker: some View {
        if showsAssistantMarker {
            LocusMessageMarker(accent: accent)
                .accessibilityIdentifier("message.\(block.id.uuidString).marker")
        } else {
            Color.clear
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var assistantResponse: some View {
                        if !block.isStreaming, let document = block.responseParts, document.isSupported {
                            ResponsePartsView(document: document, block: block, workspacePath: workspacePath,
                                selectionStore: selectionStore, selectionRowID: selectionRowID,
                                onOpenWorkspaceReference: onOpenWorkspaceReference)
                        } else {
                        MessageContentView(
                            text: block.text,
                            isStreaming: block.isStreaming,
                            reasoningText: block.reasoningText,
                            reasoningSections: block.reasoningSections,
                            reasoningFormat: block.reasoningFormat ?? .legacyTags,
                            workspacePath: workspacePath,
                            thinkingVisibility: thinkingVisibility,
                            selectionStore: selectionStore,
                            selectionRowID: selectionRowID,
                            onOpenWorkspaceReference: onOpenWorkspaceReference
                        )
                        }
    }

    private func messageActionBar(name: String) -> some View {
        HStack(spacing: 1) {
            messageActions
        }
        .frame(height: 25)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) message actions")
        .accessibilityIdentifier("message.\(block.id.uuidString).actions")
    }

    @ViewBuilder
    private var messageActions: some View {
        if block.kind == .assistant, !AssistantSegment.copyableText(from: block.text, reasoningFormat: block.reasoningFormat ?? .legacyTags).isEmpty {
            responseCopyButton
        } else if block.kind == .user {
            actionButton("doc.on.doc", help: "Copy message", identifier: "copy") {
                onCopy(.plainText)
            }
        }
        if block.kind == .user || block.kind == .assistant {
            actionButton("arrow.turn.down.right", help: "Use as draft", identifier: "useAsDraft") {
                onUseAsDraft()
            }
            .disabled(actionsDisabled)
        }
        if block.kind == .user && showsConversationActions {
            actionButton("checkmark.shield", help: "Make reusable check", identifier: "makeReusableCheck", action: onMakeReusableCheck)
                .disabled(actionsDisabled)
            actionButton("arrow.counterclockwise", help: "Rewind to this message", identifier: "rewind") {
                onRewind()
            }
            .disabled(!canRewind)
        }
        if canRegenerate {
            actionButton("arrow.clockwise", help: "Regenerate response", identifier: "regenerate") {
                onRegenerate()
            }
        }
    }

    private var responseCopyButton: some View {
        HStack(spacing: 1) {
            Button {
                copyResponse(as: .plainText)
            } label: {
                Label(
                    responseCopied ? "Copied" : "Copy",
                    systemImage: responseCopied ? "checkmark" : "doc.on.doc"
                )
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(responseCopied ? viewColors.success : viewColors.muted)
                .padding(.horizontal, 8)
                .frame(minWidth: 62, minHeight: 22)
                .background(viewColors.paperDeep.opacity(responseCopied ? 0.92 : 0.68))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.locus())
            .focused($actionsFocused)
            .help(responseCopied ? "Response copied" : "Copy full response as plain text")
            .accessibilityLabel(responseCopied ? "Response copied" : "Copy response")
            .accessibilityIdentifier("message.\(block.id.uuidString).copy")

            Menu {
                Button("Copy as Plain Text") {
                    copyResponse(as: .plainText)
                }
                .accessibilityIdentifier("message.\(block.id.uuidString).copyFormat.plainText")

                Button("Copy as Markdown") {
                    copyResponse(as: .markdown)
                }
                .accessibilityIdentifier("message.\(block.id.uuidString).copyFormat.markdown")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(viewColors.muted)
                    .frame(width: 22, height: 22)
                    .background(viewColors.paperDeep.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose response copy format")
            .accessibilityLabel("Response copy formats")
            .accessibilityIdentifier("message.\(block.id.uuidString).copyFormats")
        }
        .task(id: responseCopied) {
            guard responseCopied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            responseCopied = false
        }
    }

    private func copyResponse(as format: ResponseCopyFormat) {
        onCopy(format)
        responseCopied = true
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(showsMessageActions ? viewColors.muted : Color.clear)
                .frame(width: 24, height: 22)
                .background(
                    showsMessageActions ? viewColors.paperDeep.opacity(0.8) : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.locus())
        .focused($actionsFocused)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("message.\(block.id.uuidString).\(identifier)")
    }

    private var showsMessageActions: Bool {
        isHovering || actionsFocused
    }
}

private struct TurnCompletionMarker: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let completion: TurnCompletion

    private var color: Color {
        switch completion.outcome {
        case .complete: viewColors.success
        case .interrupted, .maxIterations, .modelCallBudget: viewColors.warning
        case .error: viewColors.coral
        }
    }

    private var symbol: String {
        switch completion.outcome {
        case .complete: "checkmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .maxIterations, .modelCallBudget: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(viewColors.line)
                .frame(height: 1)

            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(color)

            Text(completion.title)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(viewColors.inkSoft)
                .fixedSize()

            Text("· Worked for \(completion.durationText)")
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(viewColors.muted)
                .fixedSize()

            Rectangle()
                .fill(viewColors.line)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(completion.title). Worked for \(completion.durationText).")
        .accessibilityIdentifier("turnCompletion.content")
    }
}

/// The bordered icon button used for the panel-restore controls in the header.
/// Shared so the two cannot drift apart.
private struct HeaderIconButton: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 13, weight: .medium))
                .foregroundStyle(viewColors.muted)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(viewColors.line, lineWidth: 1)
                }
        }
        .buttonStyle(.locus())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct ContextUsageChip: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @State private var detailPresented = false

    /// nil when no window is known — the chip then shows a token count
    /// instead of pretending to know a percentage.
    private var fraction: Double? {
        model.contextWindowUsageFraction
    }

    /// True when the percentage is being divided by a number nothing measured,
    /// which the chip marks rather than presenting as fact.
    private var isAssumed: Bool {
        !model.contextWindowProvenance.isMeasured && fraction != nil
    }

    private var chipText: String {
        if let fraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
            return isAssumed ? "≈" + percent : percent
        }
        return "~" + model.contextUsedTokens.formatted(.number.notation(.compactName))
    }

    private var helpText: String {
        if fraction == nil { return "Context used — the model's window is unknown" }
        if isAssumed {
            return "Context window usage — assumed from the published window for this model"
        }
        return "Context window usage"
    }

    var body: some View {
        Button {
            detailPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .trim(from: 0, to: fraction.map { max($0, 0.02) } ?? 0)
                    .stroke(
                        (fraction ?? 0) > 0.8 ? viewColors.warning : viewColors.signalDeep,
                        // Dashed for a window nobody measured: the ring reads as
                        // precise, and this one is only as good as a vendor's
                        // documentation for a model id.
                        style: isAssumed
                            ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 2])
                            : StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .background {
                        Circle().stroke(viewColors.line, lineWidth: 2.5)
                    }
                    .frame(width: 12, height: 12)
                Text(chipText)
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(viewColors.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(viewColors.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(viewColors.line, lineWidth: 1)
            }
        }
        .buttonStyle(.locus())
        .help(helpText)
        .accessibilityLabel(
            fraction == nil
                ? "Context used \(chipText) tokens, window unknown"
                : "Context window \(chipText) used"
        )
        .accessibilityIdentifier("workspace.contextUsage")
        .popover(isPresented: $detailPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTEXT WINDOW")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(viewColors.muted)
                statRow(
                    "Model window",
                    model.contextWindowTokens.map { "\($0.formatted()) tokens" } ?? "Unknown"
                )
                statRow("Source", model.contextWindowProvenance.label)
                statRow("Session so far", "~\(model.contextUsedTokens.formatted()) tokens")
                if let usable = model.contextUsableTokens,
                   let window = model.contextWindowTokens, usable < window {
                    statRow("Usable for the conversation", "\(usable.formatted()) tokens")
                }
                // Cumulative across every model call this session, so they
                // routinely exceed the window above — labelled, because
                // unlabelled they read as a broken meter.
                statRow(
                    "Prompt tokens (session total)",
                    "\((model.sessionInfo?.promptTokens ?? 0).formatted())"
                )
                statRow(
                    "Completion tokens (session total)",
                    "\((model.sessionInfo?.completionTokens ?? 0).formatted())"
                )
                statRow(
                    "Context pack (next send)",
                    "\(model.includedContextTokens.formatted()) tokens · \(model.includedContextCount) files"
                )
                statRow("Messages", "\(model.sessionInfo?.messages ?? 0)")
            }
            .padding(14)
            .frame(width: 250)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.locus(size: 9))
                .foregroundStyle(viewColors.muted)
            Spacer()
            Text(value)
                .font(.locus(size: 9, weight: .semibold, design: .monospaced))
        }
    }
}

/// End-of-stream caret. An upright blinking bar reads as "still writing" in a
/// way the previous underscore-shaped rule did not — it sits on the text
/// baseline rather than below the paragraph.
private struct StreamingCaret: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(viewColors.signalDeep)
            .frame(width: 2, height: 14)
            .opacity(visible ? 0.9 : 0.15)
            .animation(LocusMotion.caretBlink(reduceMotion: reduceMotion), value: visible)
            .onAppear {
                guard !reduceMotion else { return }
                visible = false
            }
            .accessibilityHidden(true)
    }
}

private struct ThinkingDots: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(viewColors.muted)
                    .frame(width: 4, height: 4)
                    // A quiet luminance pulse communicates activity without
                    // the vestibular cost of endlessly moving dots.
                    .opacity(
                        reduceMotion
                            ? (index == 1 ? 0.9 : 0.48)
                            : (active == (index == 1) ? 0.95 : 0.42)
                    )
            }
            Text("Thinking")
                .font(.locus(size: 9))
                .foregroundStyle(viewColors.muted)
                .padding(.leading, 3)
        }
        .animation(reduceMotion ? nil : LocusMotion.activityPulse, value: active)
        .onAppear { if !reduceMotion { active = true } }
    }
}

/// One source-local reasoning item. Collapsed mode rests as a quiet inline
/// summary; Expanded mode preserves the original detailed card verbatim.
private struct ThinkingActivityView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groupID: ThinkingPresentationGroupID
    let entries: [ThinkingPresentationEntry]
    let visibility: ThinkingVisibility
    let accent: LocusAccentSelection
    let showsMarker: Bool
    let onExpansionChange: () -> Void
    @State private var expanded = false

    private var isOpen: Bool { expanded || visibility == .expanded }

    @ViewBuilder
    var body: some View {
        if visibility == .hidden {
            EmptyView()
        } else if visibility == .collapsed, !expanded {
            compactRow
        } else {
            HStack(alignment: .top, spacing: 10) {
                activityMarker
                detailedCard
            }
        }
    }

    private var compactRow: some View {
        Button {
            onExpansionChange()
            withAnimation(reduceMotion ? nil : LocusMotion.content) {
                expanded = true
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if showsMarker {
                    LocusMessageMarker(accent: accent)
                } else {
                    Image(systemName: "brain")
                        .font(.locusExact(size: 12, weight: .regular))
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }
                Text(summaryText)
                    .font(.locusExact(size: 13, weight: .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(viewColors.muted)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help("Show thought process")
        .accessibilityLabel("\(summaryText). Thought process, collapsed")
        .accessibilityIdentifier("thinkingActivity.group.\(groupIdentifier)")
    }

    @ViewBuilder
    private var activityMarker: some View {
        if showsMarker {
            LocusMessageMarker(accent: accent)
        } else {
            Color.clear
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private var detailedCard: some View {
        VStack(spacing: 0) {
            Button {
                guard visibility != .expanded else { return }
                onExpansionChange()
                withAnimation(reduceMotion ? nil : LocusMotion.content) {
                    expanded = false
                }
            } label: {
                HStack(spacing: 8) {
                    if visibility != .expanded {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(viewColors.muted)
                    }
                    Image(systemName: "brain")
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                    Text("Thought process")
                        .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("DONE")
                        .font(.locus(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(viewColors.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(visibility == .expanded)
            .accessibilityLabel(
                "Thought process, \(entries.count) update\(entries.count == 1 ? "" : "s"), "
                    + "done, \(isOpen ? "collapse" : "expand")"
            )
            .accessibilityIdentifier("thinkingActivity.group.\(groupIdentifier)")

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        MarkdownBodyView(text: entry.text, density: .compact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .accessibilityIdentifier(
                                "thinkingActivity.entry.\(entry.id.sourceBlockID.uuidString).\(entry.id.ordinal)"
                            )
                        if index < entries.count - 1 {
                            Rectangle()
                                .fill(viewColors.line)
                                .frame(height: 1)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(viewColors.line).frame(height: 1)
                }
            }
        }
        .locusCard(radius: 9)
    }

    private var summaryText: String {
        let summaries = entries.compactMap { entry -> String? in
            let plain = MarkdownPlainTextRenderer.render(entry.text)
            let normalized = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.nilIfEmpty
        }
        return summaries.joined(separator: " · ").nilIfEmpty ?? "Thought process"
    }

    private var groupIdentifier: String {
        groupID.ordinal == 0
            ? groupID.sourceBlockID.uuidString
            : "\(groupID.sourceBlockID.uuidString).\(groupID.ordinal)"
    }
}

private struct ToolActivityView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let groupID: UUID
    let tools: [ToolPayload]
    let visibility: ToolActivityVisibility
    let accent: LocusAccentSelection
    let showsMarker: Bool
    let onExpansionChange: () -> Void
    @State private var expanded = false

    private var status: ToolActivityAggregateStatus {
        ToolActivityAggregateStatus(tools: tools)
    }

    private var compactSummary: CompactToolActivitySummary {
        CompactToolActivitySummary(tools: tools)
    }

    @ViewBuilder
    var body: some View {
        switch visibility {
        case .verbose:
            EmptyView()
        case .collapsed:
            collapsedActivity
        case .hidden:
            HStack(alignment: .center, spacing: 10) {
                activityMarker
                hiddenLine
            }
        }
        if !expanded, visibility != .verbose {
            ForEach(tools.filter { $0.status != .error && $0.status != .awaitingPermission }, id: \.toolID) { tool in
                ForEach(tool.media ?? []) { reference in
                    MCPImagePreview(reference: reference)
                        .padding(.leading, 30)
                }
            }
        }
    }

    private var collapsedActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onExpansionChange()
                withAnimation(reduceMotion ? nil : LocusMotion.content) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if showsMarker {
                        LocusMessageMarker(accent: accent)
                    } else {
                        Image(systemName: compactSummary.systemImage)
                            .font(.locusExact(size: 12, weight: .regular))
                            .foregroundStyle(compactStatusColor)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 0) {
                        Text(compactSummary.title)
                            .foregroundStyle(viewColors.muted)
                        if let compactStatusSuffix {
                            Text(" · \(compactStatusSuffix)")
                                .foregroundStyle(compactStatusColor)
                        }
                    }
                    .font(.locusExact(size: 13, weight: .regular))
                    .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel(
                "\(compactSummary.title), "
                    + "\(collapsedStatusLabel), \(expanded ? "collapse" : "expand")"
            )
            .accessibilityIdentifier("toolActivity.group.\(groupID.uuidString)")

            if expanded || tools.contains(where: { $0.status == .error || $0.status == .awaitingPermission }) {
                VStack(spacing: 8) {
                    ForEach(expanded ? tools : tools.filter { $0.status == .error || $0.status == .awaitingPermission }, id: \.toolID) { tool in
                        ToolCardView(tool: tool)
                    }
                }
                .padding(.leading, 30)
            }
        }
    }

    @ViewBuilder
    private var activityMarker: some View {
        if showsMarker {
            LocusMessageMarker(accent: accent)
        } else {
            Color.clear
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private var hiddenLine: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(viewColors.line)
                .frame(height: 1)
            Image(systemName: statusSymbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(hiddenStatusLabel)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(viewColors.inkSoft)
                .fixedSize()
            Rectangle()
                .fill(viewColors.line)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hiddenStatusLabel)
        .accessibilityIdentifier("toolActivity.hidden.\(groupID.uuidString)")
    }

    private var collapsedStatusLabel: String {
        switch status {
        case .awaitingPermission: "Needs approval"
        case .running: "Running"
        case .error: "Failed"
        case .denied: "Skipped"
        case .done: "Done"
        }
    }

    private var compactStatusSuffix: String? {
        status == .done ? nil : collapsedStatusLabel
    }

    private var hiddenStatusLabel: String {
        switch status {
        case .awaitingPermission: "Action needs approval"
        case .running: "Working…"
        case .error: "Action failed"
        case .denied: "Action skipped"
        case .done: "Actions complete"
        }
    }

    private var statusSymbol: String {
        switch status {
        case .awaitingPermission: "exclamationmark.circle.fill"
        case .running: "circle.dotted"
        case .error: "xmark.circle.fill"
        case .denied: "minus.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .awaitingPermission: viewColors.warning
        case .running: viewColors.blue
        case .error: viewColors.coral
        case .denied: viewColors.muted
        case .done: viewColors.success
        }
    }

    private var compactStatusColor: Color {
        status == .done ? viewColors.muted : statusColor
    }
}

#if DEBUG
/// Metadata-only diagnostics for the exact scroll fixture's first tool header.
/// The probe neither forces layout nor changes input/AX ownership, and is
/// absent outside that fixture. In particular it never reads labels or text.
private struct ToolHeaderHitTestDiagnostics: NSViewRepresentable {
    static let isEnabled = {
        let environment = ProcessInfo.processInfo.environment
        return environment["LOCUS_UI_TESTING"] == "1"
            && environment["LOCUS_UI_TESTING_SCROLL"] == "1"
            && environment["LOCUS_UI_TESTING_TOOL_HEADER_HIT_TEST"] == "1"
    }()

    func makeNSView(context: Context) -> ToolHeaderHitTestDiagnosticView {
        ToolHeaderHitTestDiagnosticView(frame: .zero)
    }

    func updateNSView(_ view: ToolHeaderHitTestDiagnosticView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: ToolHeaderHitTestDiagnosticView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class ToolHeaderHitTestDiagnosticView: NSView {
    private var updateObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var recordPending = false
    private var recordCount = 0
    private var lastGeometry: [NSRect]?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        updateObserver = nil
        eventMonitor = nil
        guard ToolHeaderHitTestDiagnostics.isEnabled, let window else { return }
        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRecord("window.updated") }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel]) {
            [weak self] event in
            guard let self, event.window === self.window,
                  let scroll = self.enclosingScrollView,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            else { return event }
            self.scheduleRecord(event.type == .scrollWheel ? "wheel" : "leftMouseDown", force: true)
            return event
        }
        scheduleRecord("attached", force: true)
    }

    override func layout() {
        super.layout()
        scheduleRecord("layout")
    }

    private func scheduleRecord(_ event: String, force: Bool = false) {
        guard ToolHeaderHitTestDiagnostics.isEnabled, !recordPending, recordCount < 64 else { return }
        recordPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recordPending = false
            self.record(event, force: force)
        }
    }

    private func record(_ event: String, force: Bool) {
        guard recordCount < 64, let window, let root = window.contentView,
              let scroll = enclosingScrollView, let document = scroll.documentView,
              bounds.width > 0, bounds.height > 0 else { return }
        let header = convert(bounds, to: nil)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let geometry = [header, viewport, document.bounds, scroll.contentView.bounds]
        guard force || geometry != lastGeometry else { return }
        lastGeometry = geometry
        recordCount += 1
        let center = NSPoint(x: header.midX, y: header.midY)
        let rootPoint = root.superview?.convert(center, from: nil) ?? center
        let nativeHit = root.hitTest(rootPoint)
        let screenPoint = window.convertPoint(toScreen: center)
        func rect(_ value: NSRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        func className(_ value: AnyObject) -> String {
            String(NSStringFromClass(type(of: value)).prefix(512))
        }
        func ancestry(_ view: NSView?) -> [String] {
            var result: [String] = []
            var current = view
            for _ in 0..<16 {
                guard let view = current else { break }
                result.append(className(view))
                current = view.superview
            }
            return result
        }
        func accessibilityMetadata(_ value: Any?) -> [String: Any] {
            guard let value else { return ["present": false] }
            var record: [String: Any] = ["present": true, "class": className(value as AnyObject)]
            guard let accessible = value as? any NSAccessibilityProtocol else { return record }
            record["role"] = accessible.accessibilityRole()?.rawValue ?? "none"
            record["frameOnScreen"] = rect(accessible.accessibilityFrame())
            // Classify ownership, never emit a raw runtime identifier.
            let identifier = accessible.accessibilityIdentifier() ?? ""
            record["ownsExpectedHeader"] = identifier == "tool.scroll-tool-0.toggle"
            record["identifierKind"] = identifier.isEmpty ? "none"
                : (identifier == "conversation.scroll" ? "transcript"
                    : (identifier == "conversation.jumpToLatest" ? "jumpToLatest"
                        : (identifier.hasPrefix("tool.") ? "tool" : "other")))
            return record
        }
        var record: [String: Any] = [
            "event": event,
            "record": recordCount,
            "headerInWindow": rect(header),
            "headerOnScreen": rect(window.convertToScreen(header)),
            "viewportInWindow": rect(viewport),
            "headerCenterInsideViewport": viewport.contains(center),
            "documentBounds": rect(document.bounds),
            "clipBounds": rect(scroll.contentView.bounds),
            "windowVisible": window.isVisible,
            "windowUnoccluded": window.occlusionState.contains(.visible),
            "nativeHitAncestors": ancestry(nativeHit),
            "probeAncestors": ancestry(self),
            "nativeInsideTranscript": nativeHit.map { $0 === scroll || $0.isDescendant(of: scroll) } ?? false,
            "rootAX": accessibilityMetadata(root.accessibilityHitTest(screenPoint)),
            "scrollAX": accessibilityMetadata(scroll.accessibilityHitTest(screenPoint)),
            "documentAX": accessibilityMetadata(document.accessibilityHitTest(screenPoint)),
            "nativeHitAX": accessibilityMetadata(nativeHit?.accessibilityHitTest(screenPoint)),
        ]
        if let nativeHit { record["nativeHitFrameInWindow"] = rect(nativeHit.convert(nativeHit.bounds, to: nil)) }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? FileHandle.standardError.write(contentsOf: Data(("LocusToolHeaderHitTest " + json + "\n").utf8))
        }
    }

    deinit {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}
#endif

private struct ToolCardView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    let tool: ToolPayload
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                    Image(systemName: statusSymbol)
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(tool.tool)
                        .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    Text(tool.summary)
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel.uppercased())
                        .font(.locus(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(viewColors.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("\(tool.tool), \(statusLabel), \(expanded ? "collapse" : "expand")")
            .accessibilityIdentifier("tool.\(tool.toolID).toggle")
            #if DEBUG
            .background {
                if ToolHeaderHitTestDiagnostics.isEnabled, tool.toolID == "scroll-tool-0" {
                    ToolHeaderHitTestDiagnostics()
                }
            }
            #endif

            if expanded || tool.status == .awaitingPermission || tool.status == .error {
                VStack(alignment: .leading, spacing: 10) {
                    if !tool.detail.isEmpty {
                        ToolOutputText(text: tool.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(viewColors.paperDeep.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    if let result = tool.result, !result.isEmpty {
                        if DiffDetector.isDiff(result) {
                            DiffTextView(text: result)
                        } else {
                            Text(result)
                                .font(.locus(size: 9, design: .monospaced))
                                .foregroundStyle(viewColors.muted)
                                .lineLimit(14)
                                .textSelection(.enabled)
                        }
                    }

                    if tool.status == .awaitingPermission {
                        // The decision itself lives in the composer panel;
                        // the card only points there.
                        Label(
                            "Waiting for your decision in the composer below",
                            systemImage: "arrow.down.to.line"
                        )
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(viewColors.warning)
                    }
                }
                .padding(11)
                .overlay(alignment: .top) {
                    Rectangle().fill(viewColors.line).frame(height: 1)
                }
            }
            if let media = tool.media, !media.isEmpty {
                ForEach(media) { reference in
                    MCPImagePreview(reference: reference)
                        .padding(11)
                }
            }
        }
        .locusCard(radius: 9)
        // Keep the disclosure button distinct from its clipped card wrapper.
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        switch tool.status {
        case .awaitingPermission: "shield.lefthalf.filled.badge.checkmark"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .denied: "nosign"
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .awaitingPermission: viewColors.warning
        case .running: viewColors.blue
        case .done: viewColors.success
        case .error: viewColors.coral
        case .denied: viewColors.muted
        }
    }

    private var statusLabel: String {
        switch tool.status {
        case .awaitingPermission: "needs approval"
        case .running: "running"
        case .done: "done"
        case .error: "error"
        case .denied: "denied"
        }
    }
}

private struct MCPImagePreview: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    let reference: ToolMediaReference
    @State private var data: Data?
    @State private var image: NSImage?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 620, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Image returned by an MCP tool, \(reference.width) by \(reference.height)")
                    .contextMenu {
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        }
                        Button("Save As…") { save() }
                    }
            } else if let failure {
                Label(failure, systemImage: "photo")
                    .font(.locus(size: 11)).foregroundStyle(viewColors.muted)
            } else {
                ProgressView().controlSize(.small)
            }
            Text("\(reference.name) · \(reference.width)×\(reference.height)")
                .font(.locus(size: 10)).foregroundStyle(viewColors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("tool.image.\(reference.id)")
        .task(id: "\(model.currentSessionID):\(reference.id)") {
            data = nil; image = nil; failure = nil
            do {
                let loaded: Data
                do {
                    loaded = try await model.conversationBackend.chatImage(sessionID: model.currentSessionID, mediaID: reference.id)
                } catch let error as NSError where error.code == 404 && reference.sessionID != nil && reference.sessionID != model.currentSessionID {
                    loaded = try await model.conversationBackend.chatImage(sessionID: reference.sessionID!, mediaID: reference.id)
                }
                try Task.checkCancellation()
                guard let decoded = NSImage(data: loaded) else { throw URLError(.cannotDecodeContentData) }
                data = loaded; image = decoded
            } catch is CancellationError {
            } catch {
                failure = "This chat image is unavailable."
            }
        }
    }

    private func save() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = reference.name
        panel.allowedContentTypes = [UTType(mimeType: reference.mimeType) ?? .image]
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic) }
            catch { failure = "The image could not be saved." }
        }
    }
}
