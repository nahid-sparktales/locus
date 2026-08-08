import SwiftUI

/// The sidebar's shared rail. Every leading glyph — plus, magnifying glass,
/// folder, and the nav rows above them — is drawn in a fixed-width column at
/// the same inset, so they line up down the edge whatever each symbol's own
/// intrinsic width happens to be.
private enum SidebarMetrics {
    /// Inset of each control from the sidebar edge.
    static let gutter: CGFloat = 14
    /// Padding inside a control, before its icon column.
    static let rowInset: CGFloat = 10
    /// Width every leading glyph is centred in.
    static let iconColumn: CGFloat = 14
    /// Gap between the icon column and the label.
    static let iconGap: CGFloat = 8
}

struct SessionSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sessionToRename: SessionSummary?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryNavigation
            controls

            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.workspaceChatGroups.isEmpty {
                        emptyState
                    } else {
                        SectionLabel(model.showArchivedSessions ? "All Workspaces" : "Workspaces")
                        ForEach(model.workspaceChatGroups) { group in
                            WorkspaceGroupRow(
                                group: group,
                                expanded: model.isWorkspaceExpanded(group.id),
                                active: group.id == model.activeWorkspaceID,
                                actionsDisabled: model.chatNavigationDisabled,
                                onToggle: {
                                    model.setWorkspaceExpanded(
                                        group.id,
                                        expanded: !model.isWorkspaceExpanded(group.id)
                                    )
                                },
                                onOpen: { model.openWorkspace(group) },
                                onNewChat: {
                                    if let path = group.path { model.newSession(in: path) }
                                }
                            )
                            if model.isWorkspaceExpanded(group.id) {
                                if group.chats.isEmpty {
                                    Text("No chats yet")
                                        .font(.system(size: 9))
                                        .foregroundStyle(LocusTheme.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 42)
                                        .padding(.vertical, 7)
                                } else {
                                    ForEach(group.chats) { session in
                                        sessionRow(session)
                                            .padding(.leading, 14)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(maxHeight: .infinity)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .trailing) {
            Rectangle().fill(LocusTheme.line).frame(width: 1)
        }
        .alert("Rename Session", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .accessibilityIdentifier("session.rename.input")
            Button("Cancel", role: .cancel) { sessionToRename = nil }
            Button("Save") {
                if let session = sessionToRename {
                    model.renameSession(session, title: renameText)
                }
                sessionToRename = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("session.rename.save")
        } message: {
            Text("Give this conversation a name that is easy to find later.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(compact: true)

            Text("Locus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LocusTheme.ink)
                .accessibilityIdentifier("sidebar.brand")

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")
            .accessibilityLabel("Hide sidebar")
            .accessibilityIdentifier("sidebar.collapse")
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .frame(height: 60)
    }

    private var primaryNavigation: some View {
        VStack(spacing: 6) {
            JustChatControl(isChatSelected: model.justChatEnabled) { enabled in
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.setJustChatEnabled(enabled)
                }
            }

            navigationRow(
                symbol: "puzzlepiece.extension",
                title: "Plugins & MCP",
                help: "Manage plugins, MCP servers, and skills",
                accessibilityLabel: "Plugins, MCP servers, and skills",
                identifier: "sidebar.extensions"
            ) {
                model.settingsPage = .extensions
                model.settingsPresented = true
            }

            navigationRow(
                symbol: "person.crop.circle",
                title: "Manage Accounts",
                help: "Add or edit provider accounts and their API keys",
                accessibilityLabel: "Manage provider accounts",
                identifier: "sidebar.accounts"
            ) {
                model.settingsPage = .accounts
                model.settingsPresented = true
            }

            navigationRow(
                symbol: "shippingbox",
                title: "Hugging Face",
                help: "Browse and install GGUF models from Hugging Face",
                accessibilityLabel: "Browse Hugging Face models",
                identifier: "sidebar.huggingFace"
            ) {
                model.modelLibraryPresented = true
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.bottom, 10)
    }

    /// One row of the nav stack. They share an icon column with the New chat,
    /// search and workspace controls so every glyph sits on the same rail.
    private func navigationRow(
        symbol: String,
        title: String,
        help: String,
        accessibilityLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 4)
            }
            .foregroundStyle(LocusTheme.inkSoft)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Button {
                    model.newSession()
                } label: {
                    HStack(spacing: SidebarMetrics.iconGap) {
                        Image(systemName: "plus")
                            .frame(width: SidebarMetrics.iconColumn)
                        Text("New chat")
                        Spacer(minLength: 4)
                        Text("⌘N")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LocusTheme.paper)
                    .padding(.horizontal, SidebarMetrics.rowInset)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(LocusTheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.newSession")

                Menu {
                    Button("New Workspace Folder…") { model.createWorkspace() }
                        .accessibilityIdentifier("workspace.new")
                    Button("Add Existing Folder…") { model.chooseWorkspace() }
                        .accessibilityIdentifier("workspace.addExisting")
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(LocusTheme.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 36)
                .help("Add workspace")
                .accessibilityLabel("Add workspace")
                .accessibilityIdentifier("sidebar.addWorkspace")
                .disabled(model.chatNavigationDisabled)
            }

            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(LocusTheme.muted)
                TextField("Search sessions", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityLabel("Clear session search")
                }
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: 35)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
            .accessibilityIdentifier("sidebar.search")
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        SessionRow(
            session: session,
            isActive: session.id == model.currentSessionID,
            teamState: model.teamRunState(for: session)
        ) {
            model.resume(session)
        }
        .contextMenu {
            Button("Rename…") {
                renameText = session.displayTitle
                sessionToRename = session
            }
            .accessibilityIdentifier("session.\(session.id).rename")
            Button(session.isPinned ? "Unpin" : "Pin") {
                model.togglePin(session)
            }
            .accessibilityIdentifier("session.\(session.id).pin")
            Divider()
            Button("Export Markdown…") {
                model.exportSession(session)
            }
            .accessibilityIdentifier("session.\(session.id).export")
            Button(session.isArchived ? "Restore from Archive" : "Archive") {
                model.archive(session)
            }
            .disabled(session.id == model.currentSessionID)
            .accessibilityIdentifier("session.\(session.id).archive")
            Divider()
            Button("Delete Chat", role: .destructive) {
                model.deleteChat(session)
            }
            .disabled(model.isBusy || model.hasPendingPermission)
            .accessibilityIdentifier("session.\(session.id).delete")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.system(size: 18))
                .foregroundStyle(LocusTheme.muted)
            Text(model.searchQuery.isEmpty ? "No saved sessions yet" : "No matching sessions")
                .font(.system(size: 10, weight: .semibold))
            if model.searchQuery.isEmpty {
                Text("Start a conversation and it will appear here.")
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
    }

    // MARK: - Footer

    /// Two quiet rows: the workspace selector, then status with everything
    /// else tucked into an overflow menu — the rest of the sidebar stays about
    /// the conversation list.
    private var footer: some View {
        VStack(spacing: 8) {
            workspaceMenu

            HStack(spacing: 8) {
                status
                Spacer(minLength: 4)
                moreMenu
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Settings…") { model.settingsPresented = true }
                .accessibilityIdentifier("sidebar.settings")
            Button("Session Checkpoints…") { model.checkpointPresented = true }
                .accessibilityIdentifier("sidebar.checkpoints")
            Divider()
            Toggle("Show Archived Sessions", isOn: Binding(
                get: { model.showArchivedSessions },
                set: { model.setShowArchived($0) }
            ))
            .accessibilityIdentifier("sidebar.showArchived")
            Button(model.isClearingSessions ? "Clearing Saved Sessions…" : "Clear Saved Sessions…") {
                model.requestClearSavedSessions()
            }
            .disabled(model.isClearingSessions)
            .accessibilityIdentifier("sidebar.clearSessions")
            Divider()
            Button("Reconnect Agent") {
                Task { await model.bootstrap() }
            }
            .accessibilityIdentifier("sidebar.reconnect")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("More sidebar actions")
        .accessibilityLabel("More sidebar actions")
        .accessibilityIdentifier("sidebar.more")
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Choose Workspace…") { model.chooseWorkspace() }
            Button("New Workspace…") { model.createWorkspace() }
                .accessibilityIdentifier("workspace.new")
            Button("Reveal in Finder") { model.openWorkspaceInFinder() }
            if !model.recentWorkspaceProfiles.isEmpty {
                Divider()
                Section("Recent Workspaces") {
                    ForEach(model.recentWorkspaceProfiles) { profile in
                        Button {
                            model.switchWorkspace(to: profile.path)
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: profile.isAvailable ? "folder" : "exclamationmark.triangle"
                            )
                        }
                        .disabled(!profile.isAvailable)
                        .accessibilityIdentifier("workspace.profile.\(profile.path)")
                    }
                }
                if model.recentWorkspaceProfiles.contains(where: { !$0.isAvailable }) {
                    Button("Remove Missing Entries") {
                        for profile in model.recentWorkspaceProfiles where !profile.isAvailable {
                            model.removeWorkspaceProfile(profile.path)
                        }
                    }
                    .accessibilityIdentifier("workspace.removeMissingProfiles")
                }
            }
            Divider()
            Button("Settings…") { model.settingsPresented = true }
        } label: {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text("Workspace")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 40)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        // .borderlessButton centres a custom label like an NSPopUpButton title,
        // which pushed the folder glyph off the rail the New chat and search
        // icons sit on. The plain button style lays the label out verbatim.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Workspace menu")
        .accessibilityIdentifier("sidebar.workspaceMenu")
    }

    private var status: some View {
        HStack(spacing: 9) {
            statusPill(
                label: backendStatusText,
                color: backendStatusColor,
                identifier: "sidebar.backendStatus"
            )
            statusPill(
                label: model.providerLabel,
                color: runtimeColor(model.modelRuntimePhase),
                identifier: "sidebar.ollamaStatus"
            )
        }
        .font(.system(size: 8))
        .foregroundStyle(LocusTheme.muted)
        .frame(height: 22)
    }

    private func statusPill(label: String, color: Color, identifier: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var backendStatusColor: Color {
        runtimeColor(model.agentRuntimePhase)
    }

    private var backendStatusText: String {
        switch model.agentRuntimePhase {
        case .starting: "Agent starting"
        case .online: "Agent ready"
        case .recovering: "Agent recovering"
        case .unavailable: "Agent offline"
        }
    }

    private func runtimeColor(_ phase: RuntimePhase) -> Color {
        switch phase {
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
        }
    }
}

struct TeamProgressPopover: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void

    @ViewBuilder
    var body: some View {
        if runIsActive {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                content(now: timeline.date)
            }
        } else {
            // A terminal run has no elapsed clock left to update. Keeping a
            // periodic TimelineView alive here made the completed popover
            // invalidate the entire sidebar once per second indefinitely.
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let issue = model.selectedTeamRouteIssue {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(LocusTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LocusTheme.coral.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityIdentifier("teamProgress.routeIssue")
                    }

                    dispatcherSection(now: now)
                    delegatedJobs
                    modelRoster
                }
                .padding(14)
            }
            .frame(maxHeight: 430)
            Divider()
            footer
        }
        .frame(width: 370)
        .background(LocusTheme.panel)
        .accessibilityIdentifier("teamProgress.popover")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.3.sequence.fill")
                .foregroundStyle(LocusTheme.signalDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedAgentTeam?.name ?? "Team")
                    .font(.system(size: 12, weight: .bold))
                Text(progressStateTitle)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(progressStateColor)
            }
            Spacer()
            if runIsActive {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Team run in progress")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func dispatcherSection(now: Date) -> some View {
        let activity = model.dispatcherActivity
        let dispatcher = selectedDispatcher
        let startedAt = activity?.startedAt ?? model.activeWorkStartedAt
        let elapsed = startedAt.map { max(now.timeIntervalSince($0), 0) } ?? 0

        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("DISPATCHER")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: dispatcherSymbol(activity?.state))
                    .foregroundStyle(dispatcherColor(activity?.state))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity?.agentName ?? dispatcher?.name ?? "Dispatcher")
                        .font(.system(size: 10, weight: .semibold))
                    Text(dispatcherRouteLine(activity: activity, profile: dispatcher))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dispatcherDetail(activity: activity))
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(4)
                }
                Spacer(minLength: 6)
                if startedAt != nil && runIsActive {
                    Text(duration(elapsed))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            if model.orchestrationState == .dispatching,
               elapsed >= 30,
               model.agentActivities.isEmpty
            {
                Label(
                    "Still waiting for the dispatcher. No plan or delegated jobs have started.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(LocusTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("teamProgress.dispatcherSlow")
            }
        }
        .padding(10)
        .background(LocusTheme.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityIdentifier("teamProgress.dispatcher")
    }

    private var delegatedJobs: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionLabel("DELEGATED JOBS")
                Spacer()
                Text("\(completedJobs)/\(model.agentActivities.count)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            if model.agentActivities.isEmpty {
                Text(model.orchestrationState == nil
                    ? "No run yet. Send a task with this team selected."
                    : "Jobs appear here after the dispatcher returns a plan.")
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.agentActivities) { activity in
                    HStack(spacing: 7) {
                        Image(systemName: dispatcherSymbol(activity.state))
                            .foregroundStyle(dispatcherColor(activity.state))
                            .frame(width: 13)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(activityTitle(activity))
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(activity.provider) · \(activity.model)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(activity.state.title)
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
            }
        }
        .accessibilityIdentifier("teamProgress.jobs")
    }

    private var modelRoster: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("TEAM MODELS")
            ForEach(teamProfiles) { profile in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(profile.role.title)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 72, alignment: .leading)
                    Text(profile.model)
                        .font(.system(size: 8, design: .monospaced))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityIdentifier("teamProgress.models")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.teamModelCalls.formatted()) calls")
            Text("\(model.teamMeteredTokens.formatted()) hosted tokens")
            Spacer()
            if runIsActive, let runID = model.orchestrationRunID {
                Button("Stop", role: .destructive) {
                    model.cancelOrchestration(runID)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityIdentifier("teamProgress.stop")
            }
            Button("Open Runs") {
                model.selectInspectorTab(.runs)
                dismiss()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9, weight: .semibold))
            .accessibilityIdentifier("teamProgress.openRuns")
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(LocusTheme.muted)
        .padding(12)
    }

    private var selectedDispatcher: AgentProfile? {
        guard let id = model.selectedAgentTeam?.dispatcherID else { return nil }
        return model.agentProfiles.first(where: { $0.id == id })
    }

    private var teamProfiles: [AgentProfile] {
        guard let team = model.selectedAgentTeam else { return [] }
        return team.memberIDs.compactMap { id in model.agentProfiles.first(where: { $0.id == id }) }
    }

    private var completedJobs: Int {
        model.agentActivities.filter { $0.state == .completed }.count
    }

    private func activityTitle(_ activity: AgentActivity) -> String {
        if let position = activity.writerPosition, let total = activity.writerTotal {
            return "\(activity.agentName) · Coding job \(position) of \(total)"
        }
        return "\(activity.agentName) · \(activity.role.capitalized)"
    }

    private var runIsActive: Bool {
        switch model.orchestrationState {
        case .queued, .dispatching, .running, .waitingPermission, .waitingComputer,
             .waitingDispatchApproval, .reviewing, .paused:
            return true
        case .completed, .failed, .interrupted, .cancelled, .discarded, nil:
            return false
        }
    }

    private var progressStateTitle: String {
        if model.selectedTeamRouteIssue != nil { return "Needs model setup" }
        return model.orchestrationState?.title ?? "Ready"
    }

    private var progressStateColor: Color {
        if model.selectedTeamRouteIssue != nil { return LocusTheme.coral }
        return dispatcherColor(model.orchestrationState)
    }

    private func dispatcherRouteLine(activity: AgentActivity?, profile: AgentProfile?) -> String {
        if let activity, !activity.model.isEmpty {
            return [activity.provider, activity.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        guard let profile else { return "Model not configured" }
        let provider: String
        switch profile.route {
        case .localOllama:
            provider = "Local Ollama"
        case .providerAccount(let id):
            provider = model.providerAccounts.first(where: { $0.id == id })?.displayName
                ?? "Unavailable provider"
        }
        return "\(provider) · \(profile.model)"
    }

    private func dispatcherDetail(activity: AgentActivity?) -> String {
        if let activity, !activity.output.isEmpty { return activity.output }
        switch model.orchestrationState {
        case .dispatching: return "Creating and validating the job plan…"
        case .waitingDispatchApproval: return "The plan is ready and waiting for approval."
        case .running, .reviewing: return "Plan complete; team work is underway."
        case .completed: return "The team run completed."
        case .failed: return "The dispatcher or team run failed."
        default: return "Ready to route the next task."
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(LocusTheme.muted)
    }

    private func dispatcherSymbol(_ state: TeamRunState?) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted, .cancelled, .discarded: "xmark.circle.fill"
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            "pause.circle.fill"
        case .queued, .dispatching, .running, .reviewing: "circle.dotted"
        case nil: "circle"
        }
    }

    private func dispatcherColor(_ state: TeamRunState?) -> Color {
        switch state {
        case .completed: LocusTheme.success
        case .failed, .interrupted, .cancelled, .discarded: LocusTheme.coral
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            LocusTheme.warning
        case .queued, .dispatching, .running, .reviewing: LocusTheme.signalDeep
        case nil: LocusTheme.muted
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }
}

private struct WorkspaceGroupRow: View {
    let group: WorkspaceChatGroup
    let expanded: Bool
    let active: Bool
    let actionsDisabled: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onToggle) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 18, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse \(group.title)" : "Expand \(group.title)")

            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: group.isOther ? "tray.full" : "folder.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(active ? LocusTheme.signalDeep : LocusTheme.muted)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        Text("\(group.chats.count) \(group.chats.count == 1 ? "chat" : "chats")")
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer(minLength: 3)
                    if !group.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled || (group.path != nil && !group.isAvailable))
            .help(group.path ?? "Chats without saved workspace information")
            .accessibilityIdentifier("workspace.group.\(group.id)")

            if group.path != nil {
                Button(action: onNewChat) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(actionsDisabled || !group.isAvailable)
                .help("New chat in \(group.title)")
                .accessibilityLabel("New chat in \(group.title)")
                .accessibilityIdentifier("workspace.group.\(group.id).newChat")
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 38)
        .background(active ? LocusTheme.panel.opacity(0.85) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(LocusTheme.muted.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 5)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isActive: Bool
    let teamState: TeamRunState?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isActive ? "sparkles" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? LocusTheme.ink : LocusTheme.muted)
                    .frame(width: 27, height: 27)
                    .background(isActive ? LocusTheme.signal : LocusTheme.line.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let teamState {
                            Circle()
                                .fill(statusColor(teamState))
                                .frame(width: 5, height: 5)
                            Text(teamState.title)
                        } else {
                            Text(session.date, style: .relative)
                        }
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if session.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if isActive {
                    Circle()
                        .fill(LocusTheme.success)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 49)
            .background(isActive ? LocusTheme.panel : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? LocusTheme.line : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(session.displayTitle)")
        .accessibilityIdentifier("session.\(session.id)")
    }

    private func statusColor(_ state: TeamRunState) -> Color {
        switch state {
        case .completed: LocusTheme.success
        case .failed: LocusTheme.coral
        case .interrupted: LocusTheme.warning
        case .waitingPermission, .waitingComputer: LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }
}
