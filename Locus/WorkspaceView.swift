import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            contentArea
        }
        .background(LocusTheme.panel)
    }

    private var contentArea: some View {
        ZStack(alignment: .topTrailing) {
            chatContent
                .frame(
                    width: workspaceGeometry.workspaceWidth,
                    height: workspaceGeometry.workspaceHeight
                )

            if activityCenter.activityCenterPresented {
                ActivityCenterView()
                    .environmentObject(model)
                    .frame(
                        width: max(280, min(440, workspaceGeometry.workspaceWidth - 24)),
                        height: max(0, workspaceGeometry.workspaceHeight - 24)
                    )
                    .locusSurface(.floating, radius: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(LocusTheme.lineStrong, lineWidth: 1)
                    }
                    .shadow(
                        color: isLiveResizing ? .clear : .black.opacity(0.18),
                        radius: isLiveResizing ? 0 : 18,
                        x: 0,
                        y: 8
                    )
                    .padding(12)
                    .transition(LocusMotion.transition(edge: .trailing, reduceMotion: reduceMotion))
                    .zIndex(2)
            }
        }
        .clipped()
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
        HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 2) {
                WorkspaceSessionTitle(
                    sessionID: model.currentSessionID
                )

                HStack(spacing: 5) {
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
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.breadcrumb")
            }

            Spacer()

            if model.showTeamProgressInHeader, agentTeams.selectedAgentTeam != nil {
                Button {
                    teamProgressPresented.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.locus(size: 12, weight: .medium))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(teamProgressColor)
                            .frame(width: 6, height: 6)
                            .overlay {
                                Circle().stroke(LocusTheme.panel, lineWidth: 1.5)
                            }
                            .offset(x: -3, y: 3)
                    }
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
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
                    .environmentObject(model)
            }

            if model.activeTaskRecord != nil, landingFlow.taskHasChanges {
                Button("Review & Land") { landingFlow.prepareReviewAndLand() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(LocusTheme.ink)
                    .disabled(model.isBusy)
                    .help("Review this worktree's changes, checks, and landing destination")
                    .accessibilityIdentifier("workspace.reviewAndLand")
            }

            if !model.reasoningEffortOptions.isEmpty {
                WorkspaceEffortPicker()
                    .environmentObject(model)
            }

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
                    Image(systemName: "chevron.down")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(LocusTheme.white.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
                .frame(maxWidth: 176)
            }
            .buttonStyle(.locus())
            .help(agentTeams.teamModeEnabled
                ? "Active team: \(model.selectedTeamModelNames.joined(separator: ", "))"
                : "Select model")
            .accessibilityLabel(agentTeams.teamModeEnabled
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
        .padding(.leading, sidebarVisible ? 20 : 76)
        .padding(.trailing, 18)
        .frame(height: WorkspaceLayoutMetrics.toolbarHeight)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
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
        case .online: LocusTheme.success
        case .starting, .recovering: LocusTheme.warning
        case .unavailable: LocusTheme.coral
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
        if model.selectedTeamRouteIssue != nil { return LocusTheme.coral }
        switch model.orchestrationState {
        case .completed: return LocusTheme.success
        case .failed, .interrupted, .cancelled, .discarded: return LocusTheme.coral
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            return LocusTheme.warning
        case .queued, .dispatching, .running, .reviewing: return LocusTheme.signalDeep
        case nil: return LocusTheme.success
        }
    }

    private func runtimeBanner(_ message: String, recovering: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: recovering ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                .foregroundStyle(recovering ? LocusTheme.warning : LocusTheme.coral)
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
        .background((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.25))
                .frame(height: 1)
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @State private var isPresented = false

    var body: some View {
        let effort = resolvedEffort
        let label = effort.isEmpty ? "Auto" : effort.capitalized
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                Text(label)
                    .font(.locus(size: 9, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(LocusTheme.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
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

            Divider().overlay(LocusTheme.line)

            Text(
                "Applies to this workspace and takes effect on the next message. "
                + "Higher efforts think longer and cost more."
            )
            .font(.locus(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 240)
        .background(LocusTheme.white)
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
            .foregroundStyle(LocusTheme.inkSoft)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(selectedEffort == effort ? LocusTheme.paperDeep : Color.clear)
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locusWorkspaceGeometry) private var workspaceGeometry
    let sidebarVisible: Bool
    let showSidebar: () -> Void

    var body: some View {
        Group {
            switch ChatWorkspacePresentation.resolve(isSplit: model.splitViewActive) {
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
                    Rectangle().fill(LocusTheme.signalDeep).frame(width: 2)
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
    @EnvironmentObject private var model: AppModel
    let totalWidth: CGFloat
    let minimumRatio: Double
    @State private var startingRatio: Double?

    var body: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .overlay { Capsule().fill(LocusTheme.muted.opacity(0.45)).frame(width: 2, height: 34) }
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
        .background(LocusTheme.panel)
        .contentShape(Rectangle())
        .onTapGesture { model.focusChatPane(pane) }
        .onAppear { model.refreshSplitPane(session.id) }
        .onDrop(of: [.plainText], isTargeted: nil, perform: handleDrop)
        .overlay {
            Rectangle().stroke(LocusTheme.line, lineWidth: 1)
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
                        .fill(model.chatHasActiveRun(session) ? LocusTheme.success : LocusTheme.muted.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(session.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? "Saved chat")
                        .lineLimit(1)
                }
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
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
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                let blocks = model.paneBlocks(for: session.id)
                if blocks.isEmpty {
                    ProgressView("Loading chat…")
                        .controlSize(.small)
                        .foregroundStyle(LocusTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(blocks) { block in
                        PassiveChatBlockView(
                            block: block,
                            accent: model.effectiveAccent,
                            workspacePath: model.workspacePath
                        )
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
            .font(.locus(size: 12))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 44, maxHeight: 92)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(LocusTheme.paperDeep.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("split.pane.\(pane.rawValue).composer")

            HStack {
                Text(model.chatHasActiveRun(session) ? "Working in background" : "Ready")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
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
                .tint(LocusTheme.ink)
                .disabled(paneState.draft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send in \(session.displayTitle)")
                .accessibilityIdentifier("split.pane.\(pane.rawValue).send")
            }
        }
        .padding(10)
        .background(LocusTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
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
                    .background(LocusTheme.paperDeep.opacity(0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 9) {
                LocusMessageMarker(accent: accent)
                MessageContentView(
                    text: block.text,
                    isStreaming: block.isStreaming,
                    reasoningText: block.reasoningText,
                    reasoningSections: block.reasoningSections,
                    workspacePath: workspacePath,
                    thinkingVisibility: .collapsed
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            Label(block.tool?.summary ?? "Tool activity", systemImage: "wrench.and.screwdriver")
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .padding(9)
                .background(LocusTheme.paperDeep.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .note:
            Text(block.text)
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
        case .error:
            Label(block.text, systemImage: "xmark.octagon.fill")
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(LocusTheme.coral)
        }
    }
}

struct ReviewAndLandView: View {
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
                        .foregroundStyle(LocusTheme.muted)
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
                            .foregroundStyle(LocusTheme.muted)

                            ScrollView([.horizontal, .vertical]) {
                                Text(landingFlow.landingPatch.isEmpty ? "No changes." : landingFlow.landingPatch)
                                    .font(.locus(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 210)
                            .background(LocusTheme.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
                            .accessibilityIdentifier("landing.diff")
                        }

                        Divider()
                        stageHeader("2", "Review test evidence")
                        Text("Enter one explicit check per line. Locus runs up to eight sequentially in this chat’s worktree; each has a ten-minute limit.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                        TextEditor(text: $commandsText)
                            .font(.locus(size: 10, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 78)
                            .background(LocusTheme.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
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
                                    .foregroundStyle(LocusTheme.success)
                            } else if let check = landingFlow.landingCheckRun {
                                Label(
                                    check.tree == landingFlow.landingPreflight?.tree
                                        ? "Checks did not pass" : "Checks are stale",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(LocusTheme.warning)
                            } else {
                                Text("No current check evidence")
                                    .foregroundStyle(LocusTheme.muted)
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
                                            ? LocusTheme.success : LocusTheme.warning)
                                    }
                                }
                            }
                            .padding(10)
                            .background(LocusTheme.white.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Divider()
                        stageHeader("3", "Choose destination")
                        landingDestinationControl

                        if destination == "local" {
                            if landingFlow.landingPreflight?.canApplyLocal == true {
                                Text("The complete patch will be applied unstaged to Local. This chat remains in its worktree.")
                                    .font(.locus(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                            } else {
                                Label(
                                    landingFlow.landingPreflight?.conflict.nilIfEmpty
                                        ?? "The patch conflicts with Local. Both checkouts are unchanged.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.coral)
                            }
                        } else if let task = model.activeTaskRecord, task.landingCommit != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Committed on \(task.branch ?? branchName)", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(LocusTheme.success)
                                HStack {
                                    Button("Publish") { model.publishLandedWorktree() }
                                        .disabled(landingFlow.isLandingOperationRunning)
                                    Button("Open Pull Request") { model.openLandedPullRequest() }
                                    Text(task.landingCommit?.prefix(10) ?? "")
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                        } else {
                            TextField("Branch name", text: $branchName)
                                .accessibilityIdentifier("landing.branch")
                            if let branchProblem {
                                Text(branchProblem).font(.locus(size: 8)).foregroundStyle(LocusTheme.coral)
                            }
                            TextField("Commit message", text: $commitMessage, axis: .vertical)
                                .lineLimit(2...5)
                                .accessibilityIdentifier("landing.commitMessage")
                            Text("A failed commit hook leaves the new branch and staged index ready to inspect and retry.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
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
                    .foregroundStyle(checksAreCurrentAndPassing ? LocusTheme.success : LocusTheme.warning)
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
        .background(LocusTheme.panel)
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
        .background(LocusTheme.paperDeep)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
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
                .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? LocusTheme.white : Color.clear)
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
                .foregroundStyle(LocusTheme.brandInk)
                .frame(width: 22, height: 22)
                .background(LocusTheme.signal)
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
    case recent = "Recent"

    var id: String { rawValue }
}

/// Activity rows use restrained text actions, but each still needs a reliable
/// macOS click target. Padding lives inside the button style so the visible and
/// accessibility frames agree instead of exposing a ten-point-tall link.
struct ActivityActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .frame(minHeight: 22)
            .background(configuration.isPressed ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ActivityCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @State private var workflowRetryConfirmation: AttentionItem?
    @State private var clearUnavailableConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity Center")
                        .font(.locus(size: 15, weight: .bold))
                    Text(activityCenter.selectedTab == .attention
                        ? "Unresolved decisions and recoverable work only."
                        : "Work keeps running when you move between chats.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                if activityCenter.selectedTab == .activity,
                   activityCenter.visibleActivityRuns.contains(where: { activityCenter.activityIsUnseen($0) }) {
                    Button("Mark All Seen") { activityCenter.markAllActivitySeen() }
                        .accessibilityIdentifier("activity.markAllSeen")
                }
                if activityCenter.selectedTab == .activity,
                   activityCenter.visibleActivityRuns.contains(where: {
                    TeamRunState(rawValue: $0.state)?.isTerminal == true
                }) {
                    Button("Clear Finished") { model.clearFinishedActivityRuns() }
                        .accessibilityIdentifier("activity.clearFinished")
                }
                if activityCenter.selectedTab == .attention,
                   !unavailableAttentionItems.isEmpty {
                    Button("Clear Unavailable") {
                        clearUnavailableConfirmationPresented = true
                    }
                    .disabled(model.isClearingUnavailableAttention)
                    .accessibilityIdentifier("attention.clearUnavailable")
                }
                Button {
                    Task { await activityCenter.refreshActivityRuns() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("activity.refresh")
                Button {
                    withAnimation(LocusMotion.spatial) {
                        activityCenter.toggleActivityCenter()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.locus())
                .help("Close Activities")
                .accessibilityLabel("Close Activities")
                .accessibilityIdentifier("activity.close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LocusTheme.paperDeep.opacity(0.55))

            Picker("Inbox view", selection: Binding(
                get: { activityCenter.selectedTab },
                set: { activityCenter.selectTab($0) }
            )) {
                Text("Attention \(activityCenter.activityNeedsAttentionCount)")
                    .tag(ActivityCenterModel.Tab.attention)
                Text("Activity").tag(ActivityCenterModel.Tab.activity)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .accessibilityIdentifier("activity.tabSwitcher")

            if activityCenter.selectedTab == .attention {
                attentionContent
            } else if activityCenter.visibleActivityRuns.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Queued, running, and recent work appears here across all chats.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("activity.empty")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(ActivityGroup.allCases) { group in
                                let runs = runs(in: group)
                                if !runs.isEmpty {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(group.rawValue.uppercased())
                                                .font(.locus(size: 8, weight: .bold))
                                                .tracking(0.8)
                                                .foregroundStyle(group == .attention
                                                    ? LocusTheme.warning : LocusTheme.muted)
                                            Text("\(runs.count)")
                                                .font(.locus(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                        ForEach(runs) { run in
                                            activityRow(run, now: context.date)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await activityCenter.refreshActivityRuns()
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
                + "Their discarded run history will remain in Activity."
            )
        }
        .accessibilityIdentifier("activity.center")
    }

    private var unavailableAttentionItems: [AttentionItem] {
        activityCenter.attentionItems.filter {
            $0.kind == "recoverable_run" && $0.unavailable == true
        }
    }

    private var attentionContent: some View {
        Group {
            if activityCenter.attentionItems.isEmpty {
                ContentUnavailableView(
                    "Nothing Needs Attention",
                    systemImage: "checkmark.circle",
                    description: Text("Approvals, questions, recoveries, and configuration warnings appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("attention.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(AttentionGroup.allCases) { group in
                            let items = activityCenter.attentionItems.filter { $0.group == group }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(group.title.uppercased())
                                            .font(.locus(size: 8, weight: .bold))
                                            .tracking(0.8)
                                            .foregroundStyle(group == .decisions
                                                ? LocusTheme.warning : LocusTheme.muted)
                                        Text("\(items.count)")
                                            .font(.locus(size: 8, design: .monospaced))
                                            .foregroundStyle(LocusTheme.muted)
                                    }
                                    ForEach(items) { attentionRow($0) }
                                }
                            }
                        }
                    }
                    .padding(20)
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
                        ? LocusTheme.warning : LocusTheme.signalDeep)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.locus(size: 11, weight: .bold))
                    Text(item.detail)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .textSelection(.enabled)
                    if let runID = item.runID {
                        Text("Run \(runID.prefix(8))")
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }

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
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.item.\(item.id)")
    }

    @ViewBuilder
    private func attentionActions(_ item: AttentionItem) -> some View {
        HStack(spacing: 8) {
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
            Spacer()
        }
        .font(.locus(size: 8, weight: .semibold))
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
        let values = activityCenter.visibleActivityRuns.filter { activityGroup(for: $0) == group }
        if group == .queued {
            return values.sorted {
                ($0.queuePosition ?? .max, $0.createdAt)
                    < ($1.queuePosition ?? .max, $1.createdAt)
            }
        }
        return values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func activityGroup(for run: OrchestrationRun) -> ActivityGroup {
        switch run.state {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: run))
                    .font(.locus(size: 13, weight: .semibold))
                    .foregroundStyle(color(for: run))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(chatTitle(for: run))
                            .font(.locus(size: 11, weight: .bold))
                            .lineLimit(1)
                        Text(run.state.replacingOccurrences(of: "_", with: " ").uppercased())
                            .font(.locus(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: run))
                        if activityCenter.activityIsUnseen(run) {
                            Text("NEW")
                                .font(.locus(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(LocusTheme.brandInk)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(LocusTheme.signal)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        Text(workspaceTitle(for: run))
                        Text("·")
                        Text((run.runKind ?? "solo").replacingOccurrences(of: "_", with: " "))
                        Text("·")
                        Text(run.executionEnvironment == "worktree" ? "Worktree" : "Local")
                        if let position = run.queuePosition {
                            Text("· queue #\(position)")
                        }
                        Text("· \(elapsed(run, now: now))")
                    }
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    Text(run.recoveryReason?.nilIfEmpty ?? meaningfulStatus(for: run))
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Open Chat") { model.openActivityRun(run) }
                Button("Timeline") {
                    model.openActivityRun(run)
                    model.selectInspectorTab(.runs)
                }
                if run.state == "queued" {
                    Button("Top") { model.updateQueuedRun(run, action: "move_top") }
                    Button("Up") { model.updateQueuedRun(run, action: "move_up") }
                    Button("Down") { model.updateQueuedRun(run, action: "move_down") }
                    Button("Remove", role: .destructive) {
                        model.updateQueuedRun(run, action: "cancel")
                    }
                } else if ["running", "dispatching", "reviewing"].contains(run.state) {
                    if run.runKind == "team" {
                        Button("Pause") { model.pauseOrchestration(run.id) }
                    }
                    Button("Stop", role: .destructive) { model.stopActivityRun(run) }
                } else if ["paused", "interrupted"].contains(run.state), run.runKind == "team" {
                    Button("Resume") { model.resumeOrchestration(run) }
                } else if ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
                    Button(model.retryingRunIDs.contains(run.id) ? "Retrying…" : "Retry") {
                        model.retryRun(run)
                    }
                    .disabled(model.retryingRunIDs.contains(run.id))
                }
                if TeamRunState(rawValue: run.state)?.isTerminal == true {
                    Button("Remove") { model.dismissActivityRun(run) }
                        .help("Remove from Activity; the run timeline is preserved")
                        .accessibilityIdentifier("activity.remove.\(run.id)")
                }
                if run.state == "waiting_permission" {
                    Button("Allow Once") { model.answerActivityPermission(run, decision: "once") }
                    Button("Always Allow") { model.answerActivityPermission(run, decision: "always") }
                    Button("Deny", role: .destructive) {
                        model.answerActivityPermission(run, decision: "deny")
                    }
                }
                if ["waiting_computer", "waiting_dispatch_approval"].contains(run.state) {
                    Button(run.state == "waiting_computer" ? "Open Chat to Continue" : "Open Chat to Review") {
                        model.openActivityRun(run)
                    }
                }
                Spacer()
            }
            .font(.locus(size: 8, weight: .semibold))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(12)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.run.\(run.id)")
    }

    private func chatTitle(for run: OrchestrationRun) -> String {
        guard let sessionID = run.sessionID else { return "Unknown chat" }
        return sessionCatalog.snapshot.sessionsByID[sessionID]?.displayTitle ?? "Saved chat"
    }

    private func workspaceTitle(for run: OrchestrationRun) -> String {
        guard let path = run.workspaceRoot, !path.isEmpty else { return "Unknown workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
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
        case "queued": "Waiting for an execution slot"
        case "waiting_permission": "A permission answer is required"
        case "waiting_computer": "Computer Control requires this chat in the foreground"
        case "waiting_dispatch_approval": "The team plan is ready for review"
        case "paused": "Paused and ready to resume"
        case "interrupted": "The worker stopped; this run can be recovered"
        case "failed": "The run failed; inspect its timeline or retry"
        case "completed": "Completed successfully"
        case "cancelled": "Stopped"
        default: "The worker is processing this run"
        }
    }

    private func symbol(for run: OrchestrationRun) -> String {
        switch activityGroup(for: run) {
        case .attention: "exclamationmark.triangle.fill"
        case .running: "waveform.path.ecg"
        case .queued: "clock.fill"
        case .recent: run.state == "completed" ? "checkmark.circle.fill" : "circle.fill"
        }
    }

    private func color(for run: OrchestrationRun) -> Color {
        switch activityGroup(for: run) {
        case .attention: LocusTheme.warning
        case .running: LocusTheme.signalDeep
        case .queued: LocusTheme.blue
        case .recent: run.state == "completed" ? LocusTheme.success : LocusTheme.muted
        }
    }
}

private struct ScheduleRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var schedule: ScheduleModel
    let task: ScheduledTask
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: task.enabled ? "calendar.badge.clock" : "pause.circle")
                    .font(.locus(size: 13, weight: .semibold))
                    .foregroundStyle(task.lastError == nil
                        ? (task.enabled ? LocusTheme.signalDeep : LocusTheme.muted)
                        : LocusTheme.warning)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(task.name)
                            .font(.locus(size: 11, weight: .bold))
                            .lineLimit(1)
                        Text(status.uppercased())
                            .font(.locus(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(task.lastError == nil
                                ? LocusTheme.muted : LocusTheme.warning)
                    }
                    Text(nextRunDescription)
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.inkSoft)
                    Text("\(ruleDescription) · \(task.mode.title) · \(task.runner.title) · \(task.executionEnvironment.title)")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(2)
                    if let error = task.lastError?.nilIfEmpty {
                        Text(error)
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.warning)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button("Run Now") { schedule.runScheduleNow(task) }
                Button("Edit") { model.presentScheduleEditor(task: task) }
                if task.enabled {
                    Button("Pause") { schedule.setScheduleEnabled(task, enabled: false) }
                } else if task.rule.kind != .once || task.nextRunAt != nil {
                    Button("Resume") { schedule.setScheduleEnabled(task, enabled: true) }
                }
                if task.lastRunID != nil {
                    Button("Latest Result") { schedule.openLatestRun(for: task) }
                }
                Spacer()
                Button("Delete", role: .destructive) { confirmsDelete = true }
            }
            .font(.locus(size: 8, weight: .semibold))
            .buttonStyle(ActivityActionButtonStyle())
        }
        .padding(12)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule.row.\(task.id)")
        .alert("Delete \(task.name)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { schedule.deleteSchedule(task) }
        } message: {
            Text("Its generated chats and run history will be kept.")
        }
    }

    private var status: String {
        if task.lastError != nil { return "Needs attention" }
        if task.enabled { return "Active" }
        if task.rule.kind == .once && task.nextRunAt == nil { return "Completed" }
        return "Paused"
    }

    private var nextRunDescription: String {
        guard let date = task.nextRunDate else {
            return task.rule.kind == .once ? "One-time run finished" : "No next run"
        }
        return "Next \(date.formatted(date: .abbreviated, time: .shortened)) (\(task.timezone))"
    }

    private var ruleDescription: String {
        switch task.rule.kind {
        case .once: return "Once"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .interval:
            return "Every \(task.rule.every ?? 1) \((task.rule.unit ?? .hours).rawValue)"
        }
    }
}

struct ScheduleEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @State private var draft: ScheduleEditorDraft
    @State private var routeSelection: String

    init(draft: ScheduleEditorDraft) {
        _draft = State(initialValue: draft)
        _routeSelection = State(initialValue: draft.providerAccountID ?? "ollama")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.id == nil ? "New Scheduled Task" : "Edit Scheduled Task")
                        .font(.locus(size: 16, weight: .bold))
                    Text("Every occurrence continues this agent’s dedicated chat.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Cancel") { schedule.scheduleEditorDraft = nil }
                Button(draft.id == nil ? "Create" : "Save") {
                    Task { _ = await schedule.saveSchedule(draft) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(schedule.isSavingSchedule)
                .accessibilityIdentifier("scheduleEditor.save")
            }
            .padding(18)
            .background(LocusTheme.paperDeep.opacity(0.55))

            Form {
                Section("Task") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("scheduleEditor.name")
                    if model.automationWorkflowsEnabled {
                        AutomationWorkflowEditorView(workflow: $draft.workflow)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Prompt")
                                .font(.locus(size: 9, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted)
                            TextEditor(text: $draft.prompt)
                                .font(.locus(size: 11))
                                .frame(minHeight: 100)
                                .padding(5)
                                .background(LocusTheme.white.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).stroke(LocusTheme.line) }
                                .accessibilityIdentifier("scheduleEditor.prompt")
                            Text("Attachments and temporary context chips are not included.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                }

                Section("Where and how") {
                    HStack {
                        TextField("Workspace", text: $draft.workspaceRoot)
                        Button("Choose…") { chooseWorkspace() }
                    }
                    if !model.automationWorkflowsEnabled {
                        Picker("Mode", selection: $draft.mode) {
                            ForEach(WorkMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    Picker("Environment", selection: $draft.executionEnvironment) {
                        ForEach(ChatExecutionEnvironment.allCases) { environment in
                            Text(environment.title).tag(environment)
                        }
                    }
                    Picker("Runner", selection: $draft.runner) {
                        ForEach(ScheduleRunner.selectableCases) { runner in
                            Text(runner.title).tag(runner)
                        }
                    }
                    if draft.runner == .team {
                        Picker("Team", selection: $draft.teamID) {
                            Text("Choose a team").tag(String?.none)
                            ForEach(agentTeams.agentTeams) { team in
                                Text(team.name).tag(Optional(team.id.uuidString))
                            }
                        }
                        .onChange(of: draft.teamID) { _, value in
                            draft.teamName = value.flatMap { id in
                                agentTeams.agentTeams.first(where: { $0.id.uuidString == id })?.name
                            } ?? ""
                        }
                    }
                    Picker("Model account", selection: $routeSelection) {
                        Text("Local Ollama").tag("ollama")
                        ForEach(providerAccounts.providerAccounts) { account in
                            Text(account.displayName).tag(account.id.uuidString)
                        }
                    }
                    .onChange(of: routeSelection) { _, value in updateRoute(value) }
                    Picker("Model", selection: $draft.model) {
                        ForEach(availableModels, id: \.self) { modelName in
                            Text(modelName).tag(modelName)
                        }
                    }
                    TextField("Time zone", text: $draft.timezone)
                        .help("IANA time zone, for example America/Toronto")
                }

                Section("When") {
                    Picker("Repeat", selection: $draft.ruleKind) {
                        ForEach(ScheduleRuleKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    scheduleFields
                }

                Section {
                    Label(
                        "Scheduled work uses the current app permission policy. Permission and plan-approval questions pause and notify you.",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.inkSoft)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 620, height: 690)
        .background(LocusTheme.paper)
        .onAppear {
            if draft.model.isEmpty { draft.model = availableModels.first ?? "" }
        }
        .accessibilityIdentifier("scheduleEditor")
    }

    @ViewBuilder
    private var scheduleFields: some View {
        switch draft.ruleKind {
        case .once:
            DatePicker(
                "Run at", selection: $draft.oneTimeDate,
                in: Date().addingTimeInterval(60)...,
                displayedComponents: [.date, .hourAndMinute]
            )
        case .daily, .weekdays:
            DatePicker("Time", selection: $draft.clockTime, displayedComponents: .hourAndMinute)
        case .weekly:
            Picker("Day", selection: $draft.weekday) {
                ForEach(Array(weekdayNames.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(index)
                }
            }
            DatePicker("Time", selection: $draft.clockTime, displayedComponents: .hourAndMinute)
        case .interval:
            HStack {
                Stepper("Every \(draft.intervalEvery)", value: $draft.intervalEvery, in: 1...100_000)
                Picker("Unit", selection: $draft.intervalUnit) {
                    ForEach(ScheduleIntervalUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            DatePicker(
                "Starting", selection: $draft.oneTimeDate,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    private var weekdayNames: [String] {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    }

    private var availableModels: [String] {
        if routeSelection == "ollama" {
            let names = providerAccounts.installedLocalModels.map(\.name)
            return names.isEmpty ? [draft.model].filter { !$0.isEmpty } : names
        }
        guard let id = UUID(uuidString: routeSelection),
              let account = providerAccounts.providerAccounts.first(where: { $0.id == id })
        else { return [draft.model].filter { !$0.isEmpty } }
        let names = providerAccounts.accountModels[id] ?? account.kind.curatedModels
        return names.isEmpty ? [draft.model].filter { !$0.isEmpty } : names
    }

    private func updateRoute(_ value: String) {
        if value == "ollama" {
            draft.provider = "ollama"
            draft.providerAccountID = nil
        } else if let id = UUID(uuidString: value),
                  let account = providerAccounts.providerAccounts.first(where: { $0.id == id }) {
            draft.provider = account.kind == .chatGPT ? "chatgpt" : "remote"
            draft.providerAccountID = value
        }
        if !availableModels.contains(draft.model) {
            draft.model = availableModels.first ?? ""
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Workspace"
        guard panel.runModal() == .OK, let url = panel.url,
              let path = model.rememberScheduleWorkspace(url)
        else { return }
        draft.workspaceRoot = path
    }
}

/// A bounded picker instead of a native `Menu`. Provider model identifiers can
/// be hundreds of characters long (especially vLLM repository paths); AppKit's
/// menu adaptor repeatedly recomputed the window layout for those strings and
/// could pin the main thread at 100% CPU. This popover owns its width and lets
/// its contents scroll, so a long route can never resize the app or its menu.
private struct ModelPickerPopover: View {
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
                    "Manage Agents & Teams…",
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
        .background(LocusTheme.panel)
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
                        .foregroundStyle(LocusTheme.signalDeep)
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
                    .foregroundStyle(LocusTheme.muted)
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
                                ? LocusTheme.signalDeep
                                : LocusTheme.muted)
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
            .foregroundStyle(LocusTheme.muted)
    }
}

private struct TeamActivityPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(LocusMotion.spatial) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.locus(size: 8, weight: .bold))
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text("TEAM ACTIVITY")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.7)
                    if let state = model.orchestrationState {
                        Text(state.title)
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    if let task = model.activeTaskRecord {
                        Text(URL(fileURLWithPath: task.executionPath).lastPathComponent)
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                .foregroundStyle(LocusTheme.ink)
                .padding(.horizontal, 24)
                .frame(height: 31)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier("teamActivity.toggle")

            if expanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(teamRunLive.agentActivities) { activity in
                            AgentActivityRow(
                                activity: activity,
                                thinkingVisibility: model.thinkingVisibility
                            )
                        }
                        if let task = model.activeTaskRecord {
                            taskActions(task)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.75))
        .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private func taskActions(_ task: TaskRecord) -> some View {
        HStack(spacing: 8) {
            Label(
                landingFlow.taskHasChanges
                    ? "\(ByteCountFormatter.string(fromByteCount: Int64(landingFlow.taskPatchBytes), countStyle: .file)) ready"
                    : "Private checkout",
                systemImage: "arrow.triangle.branch"
            )
            .font(.locus(size: 8, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            Spacer()
            Button("Review & Land") { landingFlow.prepareReviewAndLand() }
                .disabled(model.isBusy || !landingFlow.taskHasChanges)
            Button("Copy Patch") { model.copyActiveTaskPatch() }
                .disabled(model.isBusy || !landingFlow.taskHasChanges)
            Menu {
                Button("Open Checkout") { model.openActiveTaskCheckout() }
                Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .buttonStyle(.locus())
        .controlSize(.small)
        .padding(.top, 3)
        .accessibilityIdentifier("teamActivity.taskActions")
    }
}

private struct AgentActivityRow: View {
    let activity: AgentActivity
    let thinkingVisibility: ThinkingVisibility
    @State private var outputExpanded = false
    @State private var reasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !activity.output.isEmpty { outputExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateColor)
                        .frame(width: 13)
                    Text(activity.agentName)
                        .font(.locus(size: 9, weight: .semibold))
                    if let position = activity.writerPosition, let total = activity.writerTotal {
                        Text("Coding \(position)/\(total)")
                            .font(.locus(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LocusTheme.signalDeep)
                    }
                    Text("\(activity.provider) · \(activity.model)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text("\(activity.elapsedMilliseconds / 1_000)s · \((activity.promptTokens + activity.completionTokens).formatted()) tok")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            Text(activity.goal)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(2)
            if outputExpanded, !activity.output.isEmpty {
                Text(activity.output)
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if thinkingVisibility != .hidden,
               let reasoning = activity.reasoningText,
               !reasoning.isEmpty
            {
                if thinkingVisibility == .collapsed {
                    Button {
                        reasoningExpanded.toggle()
                    } label: {
                        Label(reasoningExpanded ? "Hide reasoning" : "Show reasoning", systemImage: "brain")
                            .font(.locus(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.locus())
                }
                if reasoningExpanded || thinkingVisibility == .expanded {
                    Text(reasoning)
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.paperDeep.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(7)
        .background(LocusTheme.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var stateSymbol: String {
        switch activity.state {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted: "xmark.circle.fill"
        case .waitingPermission, .waitingComputer: "pause.circle.fill"
        default: "circle.dotted"
        }
    }

    private var stateColor: Color {
        switch activity.state {
        case .completed: LocusTheme.success
        case .failed, .interrupted: LocusTheme.coral
        case .waitingPermission, .waitingComputer: LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }
}

private struct WorkStatusStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @ObservedObject var streamingReply: StreamingReplyState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                HStack(spacing: 8) {
                    statusPill(
                        label: model.providerLabel,
                        color: runtimeColor(model.modelRuntimePhase),
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
                .foregroundStyle(LocusTheme.inkSoft)
                .frame(maxWidth: 740)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspace.workStatus")
            }
            // Match the composer's bounded column. Expanding or collapsing
            // side panels must not pull the two readiness dots toward the
            // window edges while the composer remains centered.
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: 25)
            .background(LocusTheme.panel)
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
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
        }
    }
}

/// Top-level navigation between ordinary conversations and persistent agents.
/// Work mode remains a property of each conversation's composer.
struct SidebarDestinationControl: View {
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
        .background(LocusTheme.paperDeep)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .shadow(color: LocusTheme.ink.opacity(0.08), radius: 2, y: 1)
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
                .foregroundStyle(selected ? LocusTheme.white : LocusTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule()
                            .fill(LocusTheme.inkSoft)
                            .shadow(color: LocusTheme.ink.opacity(0.16), radius: 1, y: 1)
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

private struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
    let streamingReply: StreamingReplyState
    @StateObject private var scrollCoordinator = TranscriptScrollCoordinator()
    /// Owned here, outside the lazy list, so recycling a row cannot take the
    /// selection with it — and so a drag can run from one message into another.
    @StateObject private var selection = TranscriptSelectionStore()

    private let bottomID = "conversation-bottom"

    var body: some View {
        let transcript = transcriptPresentation.snapshot
        let items = transcript.items
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if transcript.isEmpty {
                        EmptyConversationView()
                            .environmentObject(model)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            presentationRow(
                                item,
                                assistantMarkerItemIDs: transcript.assistantMarkerItemIDs,
                                assistantActionItemIDs: transcript.assistantActionItemIDs,
                                toolActivityVisibility: transcript.toolActivityVisibility,
                                thinkingVisibility: transcript.thinkingVisibility
                            )
                            .padding(.top, topSpacing(
                                before: item,
                                previous: index > 0 ? items[index - 1] : nil,
                                toolActivityVisibility: transcript.toolActivityVisibility,
                                thinkingVisibility: transcript.thinkingVisibility
                            ))
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Conversation transcript")
                .background { TranscriptSelectionScope() }
                // Like the selection scope, the bridge must live inside the
                // scroll content: from the ScrollView's own background the
                // anchor is a sibling of the platform scroll view, so
                // `enclosingScrollView` is nil and streaming output is never
                // followed.
                .background { TranscriptScrollBridge(coordinator: scrollCoordinator) }
                .frame(maxWidth: 780)
                .padding(.horizontal, 24)
                .padding(.top, transcript.isEmpty ? 0 : 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("conversation.scroll")
            .chatAttachmentDropTarget()
            .overlay(alignment: .bottom) {
                if scrollCoordinator.followState.showsJumpToLatest, !transcript.isEmpty {
                    Button {
                        scrollCoordinator.jumpToLatest(animated: true)
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(LocusTheme.white)
                            .clipShape(Capsule())
                            .overlay { Capsule().stroke(LocusTheme.line, lineWidth: 1) }
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
                scrollCoordinator.contentMayHaveChanged()
            }
            .onChange(of: model.transcriptSearchSelection) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .onChange(of: model.transcriptSearchQuery) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .onChange(of: model.transcriptJumpTarget) {
                scrollCoordinator.detach()
                scrollToOverviewTarget(proxy)
            }
            .onChange(of: model.currentSessionID) {
                selection.reset()
            }
            .onAppear {
                configureSelection(
                    for: items,
                    thinkingVisibility: transcript.thinkingVisibility
                )
            }
            .onChange(of: items.map(\.id.stableKey)) { _, _ in
                configureSelection(
                    for: items,
                    thinkingVisibility: transcript.thinkingVisibility
                )
            }
            .onChange(of: transcript.thinkingVisibility) { _, visibility in
                configureSelection(for: items, thinkingVisibility: visibility)
            }
            .environment(\.runInTerminalAction) { [weak model] command in
                model?.runCommandInTerminal(command)
            }
        }
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
        selection.spanProvider = { rowID in
            guard let source = sources[rowID] else { return [] }
            return Self.spans(
                for: source,
                rowID: rowID,
                thinkingVisibility: thinkingVisibility
            )
        }
        selection.onDragActiveChange = { active in
            scrollCoordinator.setSelectionDragActive(active)
        }
        selection.syncRows(items.map(\.id.stableKey))
    }

    private enum RowSelectionSource {
        /// A user bubble renders its text as one Markdown document.
        case whole(String)
        /// An assistant answer is split into reasoning and visible segments
        /// before rendering, and each visible one is its own subtree.
        case assistant(String)
    }

    private static func selectionSource(of item: TranscriptPresentationItem) -> RowSelectionSource? {
        switch item {
        case .block(let block):
            switch block.kind {
            case .user: .whole(block.text)
            case .assistant: .assistant(block.text)
            default: nil
            }
        case .assistantSegment(let segment):
            .assistant(segment.text)
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
        thinkingVisibility: ThinkingVisibility
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
        case .assistant(let text):
            var result: [TranscriptSelectionSpan] = []
            let segments = AssistantSegment.rendered(from: text, mode: thinkingVisibility)
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
        thinkingVisibility: ThinkingVisibility
    ) -> some View {
        switch item {
        case .block(let block):
            if block.kind == .tool, let tool = block.tool {
                detailedToolRow(
                    tool,
                    showsAssistantMarker: assistantMarkerItemIDs.contains(item.id)
                )
                .id(item.id)
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
                    showsAssistantActions: assistantActionItemIDs.contains(item.id)
                )
                .id(item.id)
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
                showsAssistantActions: assistantActionItemIDs.contains(item.id)
            )
            .id(item.id)
        case .toolGroup(let id, let tools):
            ToolActivityView(
                groupID: id,
                tools: tools,
                visibility: toolActivityVisibility,
                accent: model.effectiveAccent,
                showsMarker: assistantMarkerItemIDs.contains(item.id),
                onExpansionChange: scrollCoordinator.detach
            )
            .id(item.id)
        case .thinkingGroup(let id, let entries):
            ThinkingActivityView(
                groupID: id,
                entries: entries,
                visibility: thinkingVisibility,
                accent: model.effectiveAccent,
                showsMarker: assistantMarkerItemIDs.contains(item.id),
                onExpansionChange: scrollCoordinator.detach
            )
            .id(item.id)
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
        showsAssistantActions: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if sourceBlock.kind == .assistant,
               sourceBlock.id == model.activeStreamingAssistantID
            {
                ActiveAssistantBlockView(
                    reply: streamingReply,
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
                .id(presentationID)
            } else {
                MessageBlockView(
                    block: displayBlock,
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
                            model.copyResponse(sourceBlock.text, format: format)
                        } else {
                            model.copyMessage(sourceBlock.text)
                        }
                    },
                    onUseAsDraft: {
                        let draft = sourceBlock.kind == .assistant
                            ? AssistantSegment.copyableText(from: sourceBlock.text)
                            : sourceBlock.text
                        model.useAsDraft(draft)
                    },
                    onRewind: { model.rewind(to: sourceBlock) },
                    onRegenerate: { model.retryLastResponse() },
                    onOpenWorkspaceReference: model.openWorkspaceReference
                )
                .equatable()
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
        .overlay {
            if let style = model.transcriptMatchStyle(for: sourceBlock.id) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        style == .current
                            ? LocusTheme.signalDeep
                            : LocusTheme.lineStrong.opacity(0.7),
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
            proxy.scrollTo(destination, anchor: .center)
        }
    }

    private func scrollToOverviewTarget(_ proxy: ScrollViewProxy) {
        let transcript = transcriptPresentation.snapshot
        guard let target = model.transcriptJumpTarget,
              let block = transcript.blocksByID[target]
        else { return }
        let destination = transcript.items.first(where: { item in
            switch item {
            case .block(let candidate): return candidate.id == target
            case .assistantSegment(let segment):
                return segment.sourceBlock.id == target
            case .toolGroup(_, let tools):
                guard let toolID = block.tool?.toolID else { return false }
                return tools.contains(where: { $0.toolID == toolID })
            case .thinkingGroup(_, let entries):
                return entries.contains(where: { $0.id.sourceBlockID == target })
            }
        })?.id
        guard let destination else { return }
        withAnimation(LocusMotion.scroll) {
            proxy.scrollTo(destination, anchor: .center)
        }
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

/// Owns the underlying NSScrollView. Streaming height changes are pinned once
/// per display refresh by adjusting the clip-view origin directly; no SwiftUI
/// scrollTo transaction is created for tokens or reasoning.
@MainActor
final class TranscriptScrollCoordinator: ObservableObject {
    @Published private(set) var followState = TranscriptFollowState()

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

    func attach(from anchor: NSView) {
        guard let candidate = anchor.enclosingScrollView else { return }
        if scrollView === candidate, documentView === candidate.documentView { return }
        detachObservers()
        scrollView = candidate
        documentView = candidate.documentView
        candidate.contentView.postsBoundsChangedNotifications = true
        candidate.documentView?.postsFrameChangedNotifications = true
        lastOriginY = candidate.contentView.bounds.origin.y

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: candidate.documentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.documentFrameChanged() }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: candidate.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.boundsChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollStarted() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.userViewportChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollEnded() }
        })

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak candidate] event in
            guard let self, let candidate,
                  let window = candidate.window, event.window === window
            else { return event }
            let point = candidate.convert(event.locationInWindow, from: nil)
            guard candidate.bounds.contains(point) else { return event }

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
        updateNearBottom()
        contentMayHaveChanged()
    }

    func contentMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.followState.permitsAutomaticScroll {
                self.schedulePin()
            } else {
                self.updateNearBottom()
            }
        }
    }

    func detach() {
        pinPending = false
        displayLink?.isPaused = true
        mutateState { $0.detach() }
    }

    /// A streaming reply pins the transcript to the bottom as it grows. During
    /// a drag-selection that yanks the content out from under the pointer, so
    /// following is suspended until the drag ends.
    func setSelectionDragActive(_ active: Bool) {
        guard isSelectionDragActive != active else { return }
        isSelectionDragActive = active
        if active {
            pinPending = false
            displayLink?.isPaused = true
        } else {
            updateNearBottom()
        }
    }

    func jumpToLatest(animated: Bool = false) {
        mutateState { $0.jumpToLatest() }
        pinPending = false
        displayLink?.isPaused = true
        if animated { scrollToBottom(animated: true) }
    }

    func detachAll() {
        isRoutingVerticalWheel = false
        detachObservers()
        scrollView = nil
        documentView = nil
    }

    private func wheelMoved(deltaY: CGFloat) {
        updateNearBottom()
        if deltaY > 0 {
            detach()
        } else {
            mutateState { $0.userScrolled(upward: false) }
        }
    }

    private func liveScrollStarted() {
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
        let origin = scrollView.contentView.bounds.origin.y
        if isProgrammaticScroll {
            lastOriginY = origin
            updateNearBottom()
        } else if isUserLiveScrolling {
            userViewportChanged()
        } else {
            lastOriginY = origin
            updateNearBottom()
        }
    }

    private func documentFrameChanged() {
        if followState.permitsAutomaticScroll, !isSelectionDragActive {
            schedulePin()
        } else {
            updateNearBottom()
        }
    }

    private func updateNearBottom() {
        guard let scrollView, let documentView else { return }
        let distance = TranscriptScrollMetrics.bottomDistance(
            documentBounds: documentView.bounds,
            visibleRect: scrollView.documentVisibleRect,
            isFlipped: documentView.isFlipped
        )
        mutateState { $0.updateBottom(isNear: distance <= 24) }
    }

    private func schedulePin() {
        guard followState.permitsAutomaticScroll, let scrollView else { return }
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
        guard pinPending, followState.permitsAutomaticScroll else {
            link.isPaused = true
            return
        }
        pinPending = false
        link.isPaused = true
        scrollToBottom(animated: false)
    }

    private func scrollToBottom(animated: Bool) {
        guard let scrollView, let documentView else { return }
        let origin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: TranscriptScrollMetrics.bottomOriginY(
                documentBounds: documentView.bounds,
                viewportHeight: scrollView.contentView.bounds.height,
                isFlipped: documentView.isFlipped
            )
        )
        isProgrammaticScroll = true
        let finish = { [weak self, weak scrollView] in
            guard let self else { return }
            if let scrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.lastOriginY = scrollView.contentView.bounds.origin.y
            }
            self.isProgrammaticScroll = false
            self.updateNearBottom()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(origin)
            } completionHandler: {
                DispatchQueue.main.async(execute: finish)
            }
        } else {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            finish()
        }
    }

    private func mutateState(_ mutation: (inout TranscriptFollowState) -> Void) {
        var next = followState
        mutation(&next)
        if next != followState { followState = next }
    }

    private func detachObservers() {
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

    func makeNSView(context: Context) -> TranscriptScrollAnchorView {
        let view = TranscriptScrollAnchorView(frame: .zero)
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ view: TranscriptScrollAnchorView, context: Context) {
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
    }

    static func dismantleNSView(_ nsView: TranscriptScrollAnchorView, coordinator: ()) {
        nsView.transcriptCoordinator?.detachAll()
        nsView.transcriptCoordinator = nil
    }
}

private final class TranscriptScrollAnchorView: NSView {
    weak var transcriptCoordinator: TranscriptScrollCoordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The async hop lets SwiftUI finish inserting this view into the
        // scroll view's document hierarchy before the coordinator resolves
        // `enclosingScrollView`.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.transcriptCoordinator?.attach(from: self)
        }
    }
}

/// ⌘F search over the current conversation. Matches whole blocks (tool cards
/// excluded); ↵ and ⇧↵ walk matches with wrap-around, esc closes.
private struct TranscriptSearchBar: View {
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
                .foregroundStyle(LocusTheme.muted)

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
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("search.count")
            }

            Button {
                model.advanceTranscriptSearch(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .foregroundStyle(LocusTheme.muted)
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
            .foregroundStyle(LocusTheme.muted)
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
            .foregroundStyle(LocusTheme.muted)
            .help("Close search (esc)")
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("search.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LocusTheme.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .onAppear { focused = true }
    }
}

private struct EmptyConversationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            BrandMark(accent: model.effectiveAccent, compact: true)
                .padding(.bottom, 6)

            Text("How can Locus help?")
                .font(.locus(size: 26, weight: .medium))
                .tracking(-0.7)
                .foregroundStyle(LocusTheme.ink)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("conversation.welcome.title")

            Text("Ask a question or describe what you’d like Locus to do.")
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.muted)
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
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
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
                    .foregroundStyle(LocusTheme.signalDeep)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("TRUSTED INSTRUCTION")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                Text(context.instruction)
                    .font(.locus(size: 9, weight: .medium))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.signal.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("UNTRUSTED EVENT DATA")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.warning)
                Text(context.event.subject.isEmpty
                    ? context.event.eventType : context.event.subject)
                    .font(.locus(size: 11, weight: .bold))
                Text("From \(actor)")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
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
                .foregroundStyle(LocusTheme.muted)
            }
            Text("Normal chat permissions still apply · source event \(context.sourceEventID)")
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(LocusTheme.paperDeep.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.28), lineWidth: 1)
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

private struct MessageBlockView: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var responseCopied = false
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
    let onRewind: () -> Void
    let onRegenerate: () -> Void
    let onOpenWorkspaceReference: (WorkspaceArtifactReference) -> Void

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
                            .background(LocusTheme.paperDeep.opacity(0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(LocusTheme.line.opacity(0.7), lineWidth: 1)
                                    // A shape in an overlay takes mouse events
                                    // by default, and this one covers the whole
                                    // bubble: clicks fell through but drags did
                                    // not, so a user message could be
                                    // double-clicked and never dragged across.
                                    .allowsHitTesting(false)
                            }
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
                        MessageContentView(
                            text: block.text,
                            isStreaming: block.isStreaming,
                            reasoningText: block.reasoningText,
                            reasoningSections: block.reasoningSections,
                            workspacePath: workspacePath,
                            thinkingVisibility: thinkingVisibility,
                            selectionStore: selectionStore,
                            selectionRowID: selectionRowID,
                            onOpenWorkspaceReference: onOpenWorkspaceReference
                        )
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
                        .foregroundStyle(LocusTheme.muted)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.paperDeep.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            case .error:
                Label(block.text, systemImage: "xmark.octagon.fill")
                    .font(.locus(size: 10, weight: .medium))
                    .foregroundStyle(LocusTheme.coral)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.coral.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.coral.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LocusMotion.press, value: isHovering || actionsFocused)
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
        if block.kind == .assistant, !AssistantSegment.copyableText(from: block.text).isEmpty {
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
        if block.kind == .user {
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
                .foregroundStyle(responseCopied ? LocusTheme.success : LocusTheme.muted)
                .padding(.horizontal, 8)
                .frame(minWidth: 62, minHeight: 22)
                .background(LocusTheme.paperDeep.opacity(responseCopied ? 0.92 : 0.68))
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
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 22, height: 22)
                    .background(LocusTheme.paperDeep.opacity(0.68))
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
                .foregroundStyle(showsMessageActions ? LocusTheme.muted : Color.clear)
                .frame(width: 24, height: 22)
                .background(
                    showsMessageActions ? LocusTheme.paperDeep.opacity(0.8) : Color.clear
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
    let completion: TurnCompletion

    private var color: Color {
        switch completion.outcome {
        case .complete: LocusTheme.success
        case .interrupted, .maxIterations, .modelCallBudget: LocusTheme.warning
        case .error: LocusTheme.coral
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
                .fill(LocusTheme.line)
                .frame(height: 1)

            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(color)

            Text(completion.title)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize()

            Text("· Worked for \(completion.durationText)")
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize()

            Rectangle()
                .fill(LocusTheme.line)
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
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 13, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        }
        .buttonStyle(.locus())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct ContextUsageChip: View {
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
                        (fraction ?? 0) > 0.8 ? LocusTheme.warning : LocusTheme.signalDeep,
                        // Dashed for a window nobody measured: the ring reads as
                        // precise, and this one is only as good as a vendor's
                        // documentation for a model id.
                        style: isAssumed
                            ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 2])
                            : StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .background {
                        Circle().stroke(LocusTheme.line, lineWidth: 2.5)
                    }
                    .frame(width: 12, height: 12)
                Text(chipText)
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(LocusTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
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
                    .foregroundStyle(LocusTheme.muted)
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
                .foregroundStyle(LocusTheme.muted)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(LocusTheme.signalDeep)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(LocusTheme.muted)
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
                .foregroundStyle(LocusTheme.muted)
                .padding(.leading, 3)
        }
        .animation(reduceMotion ? nil : LocusMotion.activityPulse, value: active)
        .onAppear { if !reduceMotion { active = true } }
    }
}

/// One source-local reasoning item. Collapsed mode rests as a quiet inline
/// summary; Expanded mode preserves the original detailed card verbatim.
private struct ThinkingActivityView: View {
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
            .foregroundStyle(LocusTheme.muted)
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
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Image(systemName: "brain")
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                    Text("Thought process")
                        .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("DONE")
                        .font(.locus(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(LocusTheme.muted)
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
                                .fill(LocusTheme.line)
                                .frame(height: 1)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
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
                            .foregroundStyle(LocusTheme.muted)
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

            if expanded {
                VStack(spacing: 8) {
                    ForEach(tools, id: \.toolID) { tool in
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
                .fill(LocusTheme.line)
                .frame(height: 1)
            Image(systemName: statusSymbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(hiddenStatusLabel)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize()
            Rectangle()
                .fill(LocusTheme.line)
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
        case .awaitingPermission: LocusTheme.warning
        case .running: LocusTheme.blue
        case .error: LocusTheme.coral
        case .denied: LocusTheme.muted
        case .done: LocusTheme.success
        }
    }

    private var compactStatusColor: Color {
        status == .done ? LocusTheme.muted : statusColor
    }
}

private struct ToolCardView: View {
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
                        .foregroundStyle(LocusTheme.muted)
                    Image(systemName: statusSymbol)
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(tool.tool)
                        .font(.locus(size: 9, weight: .bold, design: .monospaced))
                    Text(tool.summary)
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel.uppercased())
                        .font(.locus(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 39)
            }
            .buttonStyle(.locus())
            .accessibilityLabel("\(tool.tool), \(statusLabel), \(expanded ? "collapse" : "expand")")
            .accessibilityIdentifier("tool.\(tool.toolID).toggle")

            if expanded || tool.status == .awaitingPermission {
                VStack(alignment: .leading, spacing: 10) {
                    if !tool.detail.isEmpty {
                        ToolOutputText(text: tool.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(LocusTheme.paperDeep.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    if let result = tool.result, !result.isEmpty {
                        if DiffDetector.isDiff(result) {
                            DiffTextView(text: result)
                        } else {
                            Text(result)
                                .font(.locus(size: 9, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
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
                        .foregroundStyle(LocusTheme.warning)
                    }
                }
                .padding(11)
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
                }
            }
        }
        .locusCard(radius: 9)
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
        case .awaitingPermission: LocusTheme.warning
        case .running: LocusTheme.blue
        case .done: LocusTheme.success
        case .error: LocusTheme.coral
        case .denied: LocusTheme.muted
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
