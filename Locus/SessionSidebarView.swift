import AppKit
import SwiftUI

/// The sidebar's shared rail. Every leading glyph — plus, magnifying glass,
/// bell, and the nav rows above them — is drawn in a fixed-width column at
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

/// Workspace groups are the parent object, so their folder remains the visual
/// anchor while the child chat rows rely on indentation and text hierarchy.
enum SidebarIconMetrics {
    static let workspaceIconSize: CGFloat = 27
    static let workspaceSymbolSize: CGFloat = 12
}

struct SessionSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sessionToRename: SessionSummary?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryNavigation
            controls

            ScrollView {
                LazyVStack(spacing: 2) {
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
                                        .font(.locus(size: 9))
                                        .foregroundStyle(LocusTheme.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 42)
                                        .padding(.vertical, 7)
                                } else {
                                    ForEach(group.chats) { session in
                                        sessionRow(session)
                                            .padding(.leading, 18)
                                    }
                                }
                            }
                        }
                    }
                    transcriptHitsSection
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Workspaces and chats")
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(maxHeight: .infinity)
        .locusSurface(.structural)
        .background {
            // Content remains below the traffic lights, while its structural
            // material fills the otherwise mismatched title-bar corner.
            LocusTheme.surfaceStructural
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle()
                // The sidebar content stays below the traffic lights, but its
                // column boundary should meet the top of the window chrome.
                .ignoresSafeArea(.container, edges: .top)
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
                .font(.locus(size: 14, weight: .bold))
                .foregroundStyle(LocusTheme.ink)
                .accessibilityIdentifier("sidebar.brand")

            Spacer(minLength: 4)

            Button {
                withAnimation(LocusMotion.spatial) {
                    model.sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.locus(size: 13, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.locus())
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
                withAnimation(LocusMotion.spatial) {
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
                    .font(.locus(size: 12, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                Text(title)
                    .font(.locus(size: 10, weight: .semibold))
                Spacer(minLength: 4)
            }
            .foregroundStyle(LocusTheme.inkSoft)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
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
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.paper.opacity(0.45))
                    }
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(LocusTheme.paper)
                    .padding(.horizontal, SidebarMetrics.rowInset)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(LocusTheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("sidebar.newSession")

                Button {
                    withAnimation(LocusMotion.spatial) {
                        model.toggleActivityCenter()
                    }
                } label: {
                    Image(systemName: model.activityCenterPresented ? "bell.fill" : "bell")
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(model.activityCenterPresented
                            ? LocusTheme.ink : LocusTheme.inkSoft)
                        .frame(width: 36, height: 36)
                        .background(model.activityCenterPresented
                            ? LocusTheme.signal.opacity(0.9)
                            : LocusTheme.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if model.activityNeedsAttentionCount > 0 {
                                Text("\(model.activityNeedsAttentionCount)")
                                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.white)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(LocusTheme.danger)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: -4)
                                    .accessibilityIdentifier("sidebar.activity.badge")
                            }
                        }
                }
                .buttonStyle(.locus())
                .help("Activities")
                .accessibilityLabel("Activities")
                .accessibilityIdentifier("sidebar.activity")
                .accessibilityValue(
                    model.activityNeedsAttentionCount > 0
                        ? "\(model.activityNeedsAttentionCount) needs attention"
                        : "No new activity"
                )
            }

            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "magnifyingglass")
                    .font(.locus(size: 11, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(LocusTheme.muted)
                TextField("Search sessions", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.locus(size: 11))
                    .focused($searchFocused)
                    .onChange(of: model.sidebarSearchFocusToken) {
                        searchFocused = true
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.locus())
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
            teamState: model.teamRunState(for: session),
            isRunning: model.chatIsRunning(session),
            startedAt: model.chatStartedAt(session)
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
            .disabled(
                session.id == model.currentSessionID || model.chatHasActiveRun(session)
            )
            .accessibilityIdentifier("session.\(session.id).archive")
            if let task = session.task,
               !FileManager.default.fileExists(atPath: task.executionPath) {
                Button("Restore Worktree") { model.restoreWorktree(for: session) }
                    .accessibilityIdentifier("session.\(session.id).restoreWorktree")
            }
            Divider()
            Button("Delete Chat", role: .destructive) {
                model.deleteChat(session)
            }
            .disabled(
                model.isBusy || model.hasPendingPermission || model.chatHasActiveRun(session)
            )
            .accessibilityIdentifier("session.\(session.id).delete")
        }
    }

    /// Cross-session transcript hits under the title matches. Rendered only
    /// while the search has enough characters to have queried the index.
    @ViewBuilder
    private var transcriptHitsSection: some View {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count >= 2 {
            SectionLabel("In conversations")
                .padding(.top, 8)
            if model.isSearchingTranscripts || model.transcriptSearchIndexing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(model.transcriptSearchIndexing
                        ? "Indexing conversations…" : "Searching…")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.vertical, 6)
                .accessibilityIdentifier("sidebar.search.progress")
            }
            if model.transcriptHits.isEmpty,
               !model.isSearchingTranscripts, !model.transcriptSearchIndexing {
                Text("No matching messages")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SidebarMetrics.rowInset)
                    .padding(.vertical, 6)
            }
            ForEach(model.transcriptHits) { hit in
                transcriptHitRow(hit)
            }
        }
    }

    private func transcriptHitRow(_ hit: TranscriptSearchHit) -> some View {
        Button {
            model.openSearchHit(hit)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: hit.role == "user" ? "person" : "sparkle")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Text(hit.title?.nilIfEmpty ?? "Untitled chat")
                        .font(.locus(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(
                        Date(timeIntervalSince1970: hit.mtime)
                            .formatted(.relative(presentation: .named))
                    )
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.muted)
                }
                Text(highlightedSnippet(hit))
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.001))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .disabled(model.chatNavigationDisabled)
        .accessibilityIdentifier("sidebar.hit.\(hit.id)")
    }

    private func highlightedSnippet(_ hit: TranscriptSearchHit) -> AttributedString {
        var text = AttributedString(hit.snippet)
        for highlight in hit.highlights {
            // Offsets are Unicode scalars (Python str positions); the hit
            // converts them on the string, then the range maps across.
            guard let stringRange = hit.stringRange(of: highlight),
                  let range = Range(stringRange, in: text)
            else { continue }
            text[range].font = .system(size: 9, weight: .bold)
            text[range].foregroundColor = LocusTheme.signalDeep
        }
        return text
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.locus(size: 18))
                .foregroundStyle(LocusTheme.muted)
            Text(model.searchQuery.isEmpty ? "No saved sessions yet" : "No matching sessions")
                .font(.locus(size: 10, weight: .semibold))
            if model.searchQuery.isEmpty {
                Text("Start a conversation and it will appear here.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
    }

    // MARK: - Footer

    /// The service indicators live with the composer, where they remain fixed
    /// as panels resize. The sidebar footer only owns workspace and app-wide
    /// controls now.
    private var footer: some View {
        VStack(spacing: 8) {
            workspaceMenu

            HStack {
                agentStatus
                Spacer()
                settingsMenu
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings…") { model.settingsPresented = true }
                .accessibilityIdentifier("sidebar.settings")
            Button("Usage & Costs…") { model.usageDashboardPresented = true }
                .accessibilityIdentifier("sidebar.usage")
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
            Image(systemName: "gearshape")
                .font(.locus(size: 12, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Settings and more")
        .accessibilityLabel("Settings and more")
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
        } label: {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "folder")
                    .font(.locus(size: 11, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("sidebar.workspaceIcon")
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text("Workspace")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.locus(size: 8, weight: .semibold))
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
        .buttonStyle(.locus())
        .menuIndicator(.hidden)
        .accessibilityLabel("Workspace menu")
        .accessibilityIdentifier("sidebar.workspaceMenu")
    }

    private var agentStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(runtimeColor(model.agentRuntimePhase))
                .frame(width: 6, height: 6)
            Text(agentStatusText)
                .lineLimit(1)
        }
        .font(.locus(size: 8))
        .foregroundStyle(LocusTheme.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.agentStatus")
    }

    private var agentStatusText: String {
        switch model.agentRuntimePhase {
        case .starting: "Starting"
        case .online: "Ready"
        case .recovering: "Recovering"
        case .unavailable: "Offline"
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

private struct SidebarResizeHandle: View {
    @EnvironmentObject private var model: AppModel
    @State private var dragStartWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LocusTheme.line)
                .frame(width: 1)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)
                .contentShape(Rectangle())
        }
        .frame(width: 14)
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .onDisappear {
            if hovering { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = model.sidebarWidth }
                    model.setSidebarWidth((dragStartWidth ?? model.sidebarWidth) + value.translation.width)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    model.commitSidebarWidth()
                }
        )
        .onTapGesture(count: 2) {
            model.resetSidebarWidth()
        }
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { model.sidebarWidth },
                    set: { width in
                        model.setSidebarWidth(width)
                        model.commitSidebarWidth()
                    }
                ),
                in: CGFloat(AppSettings.minimumSidebarWidth)...CGFloat(AppSettings.maximumSidebarWidth),
                step: 10
            ) {
                Text("Sidebar width")
            }
            .accessibilityValue("\(Int(model.sidebarWidth)) points")
            .accessibilityHint("Drag to resize. Double-click to reset.")
            .accessibilityIdentifier("sidebar.resize")
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
                            .font(.locus(size: 9, weight: .medium))
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
            Image(systemName: "person.2.fill")
                .foregroundStyle(LocusTheme.signalDeep)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedAgentTeam?.name ?? "Team")
                    .font(.locus(size: 12, weight: .bold))
                Text(progressStateTitle)
                    .font(.locus(size: 8, design: .monospaced))
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
                        .font(.locus(size: 10, weight: .semibold))
                    Text(dispatcherRouteLine(activity: activity, profile: dispatcher))
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dispatcherDetail(activity: activity))
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(4)
                }
                Spacer(minLength: 6)
                if startedAt != nil && runIsActive {
                    Text(duration(elapsed))
                        .font(.locus(size: 8, design: .monospaced))
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
                .font(.locus(size: 8, weight: .medium))
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
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            if model.agentActivities.isEmpty {
                Text(model.orchestrationState == nil
                    ? "No run yet. Send a task with this team selected."
                    : "Jobs appear here after the dispatcher returns a plan.")
                    .font(.locus(size: 9))
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
                                .font(.locus(size: 9, weight: .semibold))
                            Text("\(activity.provider) · \(activity.model)")
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(activity.state.title)
                            .font(.locus(size: 8))
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
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 72, alignment: .leading)
                    Text(profile.model)
                        .font(.locus(size: 8, design: .monospaced))
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
            if presentation?.canStop == true, let runID = model.orchestrationRunID {
                Button("Stop", role: .destructive) {
                    model.cancelOrchestration(runID)
                }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityIdentifier("teamProgress.stop")
            }
            Button("Open Runs") {
                if let runID = model.orchestrationRunID {
                    model.openTeamRun(runID)
                } else {
                    model.selectInspectorTab(.runs)
                }
                dismiss()
            }
            .buttonStyle(.locus())
            .font(.locus(size: 9, weight: .semibold))
            .accessibilityIdentifier("teamProgress.openRuns")
        }
        .font(.locus(size: 8, design: .monospaced))
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
        presentation?.isActivelyOwned == true
    }

    private var presentation: TeamRunPresentation? {
        guard let runID = model.orchestrationRunID else { return nil }
        let durable = model.orchestrationRuns.first(where: { $0.id == runID })
        return model.teamRunPresentation(for: runID, durable: durable)
    }

    private var progressStateTitle: String {
        if model.selectedTeamRouteIssue != nil { return "Needs model setup" }
        return presentation?.state.title ?? "Ready"
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
            .font(.locus(size: 8, weight: .bold))
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
                    .font(.locus(size: 8, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 18, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel(expanded ? "Collapse \(group.title)" : "Expand \(group.title)")

            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: group.isOther ? "tray.full" : "folder.fill")
                        .font(.locus(size: SidebarIconMetrics.workspaceSymbolSize, weight: .medium))
                        .foregroundStyle(active ? LocusTheme.signalDeep : LocusTheme.muted)
                        .frame(
                            width: SidebarIconMetrics.workspaceIconSize,
                            height: SidebarIconMetrics.workspaceIconSize
                        )
                        .accessibilityIdentifier("workspace.group.icon.\(group.id)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .lineLimit(1)
                        Text("\(group.chats.count) \(group.chats.count == 1 ? "chat" : "chats")")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer(minLength: 3)
                    if !group.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(actionsDisabled || (group.path != nil && !group.isAvailable))
            .help(group.path ?? "Chats without saved workspace information")
            .accessibilityIdentifier("workspace.group.\(group.id)")

            if group.path != nil {
                Button(action: onNewChat) {
                    Image(systemName: "plus")
                        .font(.locus(size: 9, weight: .bold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
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
            .font(.locus(size: 8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(LocusTheme.muted)
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
    let isRunning: Bool
    let startedAt: Date?
    let action: () -> Void

    private var showsActivity: Bool { isRunning || teamState != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    if isRunning || teamState != nil {
                        HStack(spacing: 4) {
                            if isRunning {
                                Circle()
                                    .fill(LocusTheme.signalDeep)
                                    .frame(width: 5, height: 5)
                                if let startedAt {
                                    Text(startedAt, style: .timer)
                                } else {
                                    Text("Running")
                                }
                            } else if let teamState {
                                Circle()
                                    .fill(statusColor(teamState))
                                    .frame(width: 5, height: 5)
                                Text(sidebarStatusTitle(teamState))
                            }
                        }
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("session.\(session.id).activity")
                    }
                }
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if session.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if isActive {
                    Circle()
                        .fill(LocusTheme.success)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: showsActivity ? 42 : 34)
            .background(isActive ? LocusTheme.panel : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? LocusTheme.line : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.locus())
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

    private func sidebarStatusTitle(_ state: TeamRunState) -> String {
        switch state {
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval:
            "Needs Attention"
        default:
            state.title
        }
    }
}
