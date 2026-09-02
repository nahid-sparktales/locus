import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct ChatFolderEditorRequest: Identifiable {
    let id = UUID()
    let workspace: String
    let parentID: String?
    let folder: ChatFolderRecord?

    var title: String { folder == nil ? "New Chat Folder" : "Rename Chat Folder" }
}

private struct AgentSidebarGroupModel: Identifiable {
    let id: String
    let name: String
    let tasks: [SessionSummary]
}

/// Cross-session transcript results observe their child model at the smallest
/// owning boundary, so result updates do not invalidate the whole sidebar or AppModel.
private struct TranscriptHitsSection: View {
    let snapshot: SessionCatalogSnapshot
    @ObservedObject var transcriptSearch: TranscriptSearchModel
    let navigationDisabled: Bool
    let onOpen: (TranscriptSearchHit) -> Void

    @ViewBuilder
    var body: some View {
        let query = snapshot.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count >= 2 {
            SectionLabel("In conversations")
                .padding(.top, 8)
            if transcriptSearch.isSearchingTranscripts || transcriptSearch.transcriptSearchIndexing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(transcriptSearch.transcriptSearchIndexing
                        ? "Indexing conversations…" : "Searching…")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.vertical, 6)
                .accessibilityIdentifier("sidebar.search.progress")
            }
            if transcriptSearch.transcriptHits.isEmpty,
               !transcriptSearch.isSearchingTranscripts,
               !transcriptSearch.transcriptSearchIndexing {
                Text("No matching messages")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SidebarMetrics.rowInset)
                    .padding(.vertical, 6)
            }
            ForEach(transcriptSearch.transcriptHits) { hit in
                transcriptHitRow(hit)
            }
        }
    }

    private func transcriptHitRow(_ hit: TranscriptSearchHit) -> some View {
        Button { onOpen(hit) } label: {
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
        .disabled(navigationDisabled)
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
}

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
    static let workspaceIconSize: CGFloat = 22
    static let workspaceSymbolSize: CGFloat = 11
}

struct SessionSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionToRename: SessionSummary?
    @State private var renameText = ""
    @State private var workspaceToRemove: WorkspaceChatGroup?
    @State private var folderToDelete: ChatFolderRecord?
    @State private var folderEditor: ChatFolderEditorRequest?
    @State private var folderEditorName = ""
    @State private var collapsedAgentIDs: Set<String> = []
    @State private var agentToDelete: EventTrigger?
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let snapshot = sessionCatalog.snapshot
        VStack(spacing: 0) {
            header
            controls

            ScrollView {
                LazyVStack(spacing: 2) {
                    sectionHeader(snapshot: snapshot)
                    if searchExpanded {
                        searchField(snapshot: snapshot)
                            .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
                    }
                    if model.sidebarDestination == .agents {
                        if snapshot.agentSessions.isEmpty {
                            agentEmptyState(snapshot: snapshot)
                        } else {
                            ForEach(agentGroups(snapshot: snapshot)) { agent in
                                agentGroupRow(agent)
                                if !collapsedAgentIDs.contains(agent.id) {
                                    ForEach(agent.tasks) { session in
                                        sessionRow(session, snapshot: snapshot)
                                            .padding(.leading, 22)
                                    }
                                }
                            }
                        }
                    } else {
                        if snapshot.sidebarGroups.isEmpty {
                            emptyState(snapshot: snapshot)
                        } else {
                            ForEach(snapshot.sidebarGroups) { sidebarGroup in
                                let group = sidebarGroup.group
                                WorkspaceGroupRow(
                                    group: group,
                                    expanded: snapshot.expandedWorkspaceIDs.contains(group.id),
                                    active: group.id == snapshot.activeWorkspaceID,
                                    actionsDisabled: model.chatNavigationDisabled,
                                    onToggle: {
                                        model.setWorkspaceExpanded(
                                            group.id,
                                            expanded: !snapshot.expandedWorkspaceIDs.contains(group.id)
                                        )
                                    },
                                    onOpen: { model.openWorkspace(group) },
                                    onNewChat: {
                                        if let path = group.path { model.newSession(in: path) }
                                    }
                                )
                                .contextMenu {
                                    if let path = group.path {
                                        Button("New Folder…") {
                                            requestFolderEditor(workspace: path, parentID: nil)
                                        }
                                        .accessibilityIdentifier("workspace.group.\(group.id).newFolder")
                                        Divider()
                                        Button("Remove from Sidebar") {
                                            requestWorkspaceRemoval(group)
                                        }
                                        .disabled(
                                            group.id == snapshot.activeWorkspaceID
                                                || model.workspaceHasActiveRun(group)
                                        )
                                        .accessibilityIdentifier("workspace.group.\(group.id).remove")
                                    }
                                }
                                .modifier(ChatSidebarDropTarget(
                                    targetFolderID: nil,
                                    index: nil,
                                    targetWorkspace: group.path
                                ))
                                if snapshot.expandedWorkspaceIDs.contains(group.id) {
                                    if group.chats.isEmpty && sidebarGroup.rootFolders.isEmpty {
                                        Text("No chats yet")
                                            .font(.locus(size: 9))
                                            .foregroundStyle(LocusTheme.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 42)
                                            .padding(.vertical, 7)
                                    } else {
                                        ForEach(sidebarGroup.rootFolders) { folderNode in
                                            ChatFolderBranchView(
                                                node: folderNode,
                                                depth: 0,
                                                onCreateFolder: { workspace, parentID in
                                                    requestFolderEditor(
                                                        workspace: workspace,
                                                        parentID: parentID
                                                    )
                                                },
                                                onRenameFolder: { folder in
                                                    requestFolderEditor(
                                                        workspace: folder.workspace,
                                                        parentID: folder.parentID,
                                                        folder: folder
                                                    )
                                                },
                                                onDeleteFolder: { folderToDelete = $0 },
                                                sessionContent: { session in
                                                    AnyView(sessionRow(session, snapshot: snapshot))
                                                }
                                            )
                                            .environmentObject(model)
                                        }
                                        ForEach(sidebarGroup.unfiledChats) { session in
                                            sessionRow(session, snapshot: snapshot)
                                                .padding(.leading, 18)
                                        }
                                    }
                                }
                            }
                        }
                        TranscriptHitsSection(
                            snapshot: snapshot,
                            transcriptSearch: model.transcriptSearch,
                            navigationDisabled: model.chatNavigationDisabled,
                            onOpen: model.openSearchHit
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    model.sidebarDestination == .agents ? "Agents and chats" : "Workspaces and chats"
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            footer(snapshot: snapshot)
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
        .onChange(of: snapshot.sidebarSearchFocusToken) {
            withAnimation(LocusMotion.spatial) { searchExpanded = true }
            // The field is created by this same update, so focus has to wait
            // one main-actor turn for it to exist.
            Task { @MainActor in searchFocused = true }
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
        .alert(folderEditor?.title ?? "Chat Folder", isPresented: Binding(
            get: { folderEditor != nil },
            set: { if !$0 { folderEditor = nil } }
        )) {
            TextField("Folder name", text: $folderEditorName)
                .accessibilityIdentifier("chatFolder.name")
            Button("Cancel", role: .cancel) { folderEditor = nil }
            Button(folderEditor?.folder == nil ? "Create" : "Save") {
                guard let request = folderEditor else { return }
                if let folder = request.folder {
                    model.renameChatFolder(folder, name: folderEditorName)
                } else {
                    model.createChatFolder(
                        in: request.workspace,
                        name: folderEditorName,
                        parentID: request.parentID
                    )
                }
                folderEditor = nil
            }
            .disabled(folderEditorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chatFolder.save")
        } message: {
            Text("Folders organize chats inside this workspace without changing where they run.")
        }
        .confirmationDialog(
            "Remove \(workspaceToRemove?.title ?? "this workspace") from the sidebar?",
            isPresented: Binding(
                get: { workspaceToRemove != nil },
                set: { if !$0 { workspaceToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove and Archive Chats", role: .destructive) {
                if let group = workspaceToRemove {
                    model.removeWorkspaceFromSidebar(group)
                }
                workspaceToRemove = nil
            }
            .accessibilityIdentifier("workspace.remove.confirm")
            Button("Cancel", role: .cancel) { workspaceToRemove = nil }
        } message: {
            Text(
                "Its \(removableChatCount) \(removableChatCount == 1 ? "chat moves" : "chats move") "
                    + "to the archive — turn on Show Archived Sessions to restore them. "
                    + "Files on disk are not touched."
            )
        }
        .confirmationDialog(
            "Delete \(agentToDelete?.name ?? "this agent")?",
            isPresented: Binding(
                get: { agentToDelete != nil },
                set: { if !$0 { agentToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Agent", role: .destructive) {
                if let agentToDelete { model.eventAutomations.deleteTrigger(agentToDelete) }
                agentToDelete = nil
            }
            .accessibilityIdentifier("agent.delete.confirm")
            Button("Cancel", role: .cancel) { agentToDelete = nil }
        } message: {
            Text("It stops listening for events. Its chats stay where they are.")
        }
        .confirmationDialog(
            "Delete \(folderToDelete?.name ?? "this folder")?",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folderToDelete { model.deleteChatFolder(folderToDelete) }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("Chats and subfolders move up one level. No conversations are deleted.")
        }
    }

    private var removableChatCount: Int {
        workspaceToRemove.map { model.removableSidebarChats(for: $0).count } ?? 0
    }

    /// Groups that still hold unarchived chats deserve a confirmation,
    /// because removal archives those chats — including ones the current
    /// search or archive filter is hiding. A chat-free row just disappears.
    private func requestWorkspaceRemoval(_ group: WorkspaceChatGroup) {
        if model.removableSidebarChats(for: group).isEmpty {
            model.removeWorkspaceFromSidebar(group)
        } else {
            workspaceToRemove = group
        }
    }

    private func requestFolderEditor(
        workspace: String, parentID: String?, folder: ChatFolderRecord? = nil
    ) {
        folderEditorName = folder?.name ?? ""
        folderEditor = ChatFolderEditorRequest(
            workspace: workspace,
            parentID: parentID,
            folder: folder
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(accent: model.effectiveAccent, compact: true)

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

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            SidebarDestinationControl(destination: model.sidebarDestination) { destination in
                withAnimation(LocusMotion.spatial) {
                    model.sidebarDestination = destination
                }
            }

            navigationRow(
                symbol: "person.crop.circle",
                title: "Manage Accounts",
                help: "Add or edit provider accounts and their API keys",
                accessibilityLabel: "Manage Accounts",
                identifier: "sidebar.accounts"
            ) {
                model.presentSettings(.accounts)
            }

            primaryCreationButton

            // The configuration host is mounted before any optional editor is
            // presented, so global shortcuts always have a live sheet anchor.
            HStack(spacing: 7) {
                secondaryButton(
                    symbol: "gearshape.2",
                    title: "Manage Agents",
                    help: "Agents, their sources, and the events they have handled",
                    accessibilityLabel: "Manage Agents",
                    identifier: "sidebar.configureAgent"
                ) {
                    model.presentConfigureAgent(draftText: model.draftText)
                }

                activityButton
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.bottom, 12)
    }

    /// Each destination creates the object it is about: a chat in Ask, an agent
    /// in Agents. Chatting with a particular agent lives on that agent's row,
    /// where which agent it belongs to is unambiguous.
    private var primaryCreationButton: some View {
        let isAgents = model.sidebarDestination == .agents
        return Button {
            model.newChatForSidebarDestination()
        } label: {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: "plus")
                    .frame(width: SidebarMetrics.iconColumn)
                Text(isAgents ? "New agent" : "New chat")
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
        .help(isAgents
            ? "Configure an agent that wakes on email, messages, webhooks, or a price (⌘N)"
            : "Start a new chat (⌘N)")
        .accessibilityLabel(isAgents ? "New agent" : "New chat")
        .accessibilityIdentifier(isAgents ? "sidebar.newAgent" : "sidebar.newSession")
    }

    private var activityButton: some View {
        Button {
            withAnimation(LocusMotion.spatial) {
                activityCenter.toggleActivityCenter()
            }
        } label: {
            Image(systemName: activityCenter.activityCenterPresented ? "bell.fill" : "bell")
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(activityCenter.activityCenterPresented
                    ? LocusTheme.ink : LocusTheme.inkSoft)
                .frame(width: 36, height: 36)
                .background(activityCenter.activityCenterPresented
                    ? LocusTheme.signal.opacity(0.9)
                    : LocusTheme.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if activityCenter.activityNeedsAttentionCount > 0 {
                        Text("\(activityCenter.activityNeedsAttentionCount)")
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
            activityCenter.activityNeedsAttentionCount > 0
                ? "\(activityCenter.activityNeedsAttentionCount) needs attention"
                : "No new activity"
        )
    }

    /// A quiet destination row. It shares the icon column with New chat and
    /// the workspace controls, so every glyph sits on the same rail.
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

    /// New chat's shape and weight, one step quieter in fill so the primary
    /// action still leads its stack.
    private func secondaryButton(
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
                    .frame(width: SidebarMetrics.iconColumn)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.locus(size: 11, weight: .semibold))
            .foregroundStyle(LocusTheme.inkSoft)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(LocusTheme.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .buttonStyle(.locus())
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Search

    /// Search is a section control now: the glyph beside WORKSPACES reveals
    /// the field, so an unused search box no longer occupies the sidebar.
    private func sectionHeader(snapshot: SessionCatalogSnapshot) -> some View {
        HStack(spacing: 0) {
            SectionLabel(
                model.sidebarDestination == .agents
                    ? "Agents"
                    : (snapshot.showArchivedSessions ? "All Workspaces" : "Workspaces")
            )
            Button {
                withAnimation(LocusMotion.spatial) {
                    if searchExpanded, snapshot.searchQuery.isEmpty {
                        searchExpanded = false
                    } else {
                        searchExpanded = true
                        searchFocused = true
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(searchExpanded ? LocusTheme.ink : LocusTheme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.locus(.icon))
            .help("Search sessions (⇧⌘F)")
            .accessibilityLabel("Search sessions")
            .accessibilityValue(searchExpanded ? "Shown" : "Hidden")
            .accessibilityIdentifier("sidebar.search.toggle")
            if model.sidebarDestination == .ask {
                Button {
                    requestFolderEditor(
                        workspace: snapshot.activeWorkspaceID,
                        parentID: nil
                    )
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.locus(.icon))
                .help("New chat folder (⇧⌘N)")
                .accessibilityLabel("New chat folder")
                .accessibilityIdentifier("sidebar.newChatFolder")
            }
        }
        .padding(.trailing, 6)
    }

    private func searchField(snapshot: SessionCatalogSnapshot) -> some View {
        HStack(spacing: SidebarMetrics.iconGap) {
            Image(systemName: "magnifyingglass")
                .font(.locus(size: 11, weight: .medium))
                .frame(width: SidebarMetrics.iconColumn)
                .foregroundStyle(LocusTheme.muted)
            TextField("Search sessions", text: Binding(
                get: { snapshot.searchQuery },
                set: { sessionCatalog.setSearchQuery($0) }
            ))
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .focused($searchFocused)
            if !snapshot.searchQuery.isEmpty {
                Button {
                    sessionCatalog.setSearchQuery("")
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .accessibilityLabel("Clear session search")
                .accessibilityIdentifier("sidebar.search.clear")
            }
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .frame(height: 32)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        // Escape leaves the way it arrived: empty query, field put away.
        .onExitCommand {
            sessionCatalog.setSearchQuery("")
            withAnimation(LocusMotion.spatial) { searchExpanded = false }
        }
        .accessibilityIdentifier("sidebar.search")
    }

    @ViewBuilder
    private func sessionRow(
        _ session: SessionSummary,
        snapshot: SessionCatalogSnapshot
    ) -> some View {
        SessionRow(
            session: session,
            isActive: session.id == model.currentSessionID,
            teamState: model.teamRunState(for: session),
            isRunning: model.chatIsRunning(session),
            startedAt: model.chatStartedAt(session),
            showsAgentIcon: model.sidebarDestination != .agents
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
            Button("Duplicate") {
                model.duplicateSession(session)
            }
            .disabled(model.chatHasActiveRun(session))
            .accessibilityIdentifier("session.\(session.id).duplicate")
            Button("Open in Other Pane") {
                model.openInOtherPane(session)
            }
            .disabled(session.id == model.currentSessionID)
            .accessibilityIdentifier("session.\(session.id).openOtherPane")
            if session.executionEnvironment == .worktree {
                Button("Duplicate with Worktree") {
                    model.duplicateSession(session, withWorktree: true)
                }
                .disabled(
                    session.isArchived || model.chatHasActiveRun(session)
                        || !snapshot.availableExecutionSessionIDs.contains(session.id)
                )
                .accessibilityIdentifier("session.\(session.id).duplicateWorktree")
            }
            if !session.isAgentChat {
                Menu("Move to Folder") {
                    Button("Workspace Root") { model.moveChat(session, to: nil) }
                        .disabled(session.folderID == nil)
                    let workspace = snapshot.workspaceIDBySessionID[session.id]
                    let folderTargets = workspace.flatMap { snapshot.foldersByWorkspaceID[$0] } ?? []
                    ForEach(folderTargets) { folder in
                        Button(folder.name) { model.moveChat(session, to: folder.id) }
                            .disabled(session.folderID == folder.id)
                    }
                }
                Button("Move Earlier") { model.reorderChat(session, offset: -1) }
                    .accessibilityIdentifier("session.\(session.id).moveEarlier")
                Button("Move Later") { model.reorderChat(session, offset: 1) }
                    .accessibilityIdentifier("session.\(session.id).moveLater")
            }
            Divider()
            Menu("Export") {
                ForEach(ChatExportFormat.allCases) { format in
                    Button("\(format.title)…") {
                        model.exportSession(session, format: format)
                    }
                }
            }
            .accessibilityIdentifier("session.\(session.id).export")
            Button(session.isArchived ? "Restore from Archive" : "Archive") {
                model.archive(session)
            }
            .disabled(
                session.id == model.currentSessionID || model.chatHasActiveRun(session)
            )
            .accessibilityIdentifier("session.\(session.id).archive")
            if session.task != nil,
               !snapshot.availableExecutionSessionIDs.contains(session.id) {
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
        .onDrag {
            NSItemProvider(object: "locus-chat:\(session.id)" as NSString)
        }
        .modifier(ChatSidebarDropTarget(
            targetFolderID: session.folderID,
            index: session.sortOrder,
            targetWorkspace: snapshot.workspaceIDBySessionID[session.id]
        ))
        .accessibilityAction(named: "Move Earlier") {
            model.reorderChat(session, offset: -1)
        }
        .accessibilityAction(named: "Move Later") {
            model.reorderChat(session, offset: 1)
        }
    }

    /// Distinct agents, which is what the footer's label promises — several
    /// chats can belong to one agent.
    private func agentCount(snapshot: SessionCatalogSnapshot) -> Int {
        Set(snapshot.agentSessions.compactMap { $0.agentTriggerID?.nilIfEmpty }).count
    }

    private func agentGroups(snapshot: SessionCatalogSnapshot) -> [AgentSidebarGroupModel] {
        Dictionary(grouping: snapshot.agentSessions) { session in
            session.agentTriggerID ?? session.id
        }
        .map { triggerID, tasks in
            AgentSidebarGroupModel(
                id: triggerID,
                name: tasks.compactMap(\.agentName).first?.nilIfBlank
                    ?? tasks[0].displayTitle,
                tasks: tasks.sorted {
                    if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                    return $0.id < $1.id
                }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func agentGroupRow(_ agent: AgentSidebarGroupModel) -> some View {
        let expanded = !collapsedAgentIDs.contains(agent.id)
        let trigger = model.eventAutomations.triggers.first { $0.id == agent.id }
        let status = AgentOverview.status(for: trigger)
        return Button {
            withAnimation(LocusMotion.spatial) {
                if expanded {
                    collapsedAgentIDs.insert(agent.id)
                } else {
                    collapsedAgentIDs.remove(agent.id)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.locus(size: 7, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 9)
                Image(locusSymbol: LocusSymbol.robot)
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(status.isWarning ? LocusTheme.warning : LocusTheme.signalDeep)
                    .frame(width: 21, height: 21)
                    .accessibilityHidden(true)
                Text(agent.name)
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(1)
                if status != .active {
                    Image(systemName: agentStatusSymbol(status))
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(status.isWarning ? LocusTheme.warning : LocusTheme.muted)
                        .help(status.detail)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                Text("\(agent.tasks.count)")
                    .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(LocusTheme.white.opacity(0.36))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .contextMenu {
            Button("New Chat with \(agent.name)") {
                model.newAgentChat(triggerID: agent.id)
            }
            .accessibilityIdentifier("agent.\(agent.id).newChat")
            if let trigger {
                Button("Edit Agent…") {
                    model.editAgentTrigger(trigger, isDedicatedAgent: true)
                }
                .accessibilityIdentifier("agent.\(agent.id).edit")
                Button(trigger.enabled ? "Pause Agent" : "Resume Agent") {
                    model.eventAutomations.setTrigger(trigger, enabled: !trigger.enabled)
                }
                .accessibilityIdentifier("agent.\(agent.id).toggle")
                Divider()
                Button("Delete Agent…", role: .destructive) {
                    agentToDelete = trigger
                }
                .accessibilityIdentifier("agent.\(agent.id).delete")
            }
        }
        .help(status.detail)
        .accessibilityLabel("\(agent.name) agent")
        .accessibilityValue(
            "\(status.title), \(agent.tasks.count) \(agent.tasks.count == 1 ? "chat" : "chats"), "
                + (expanded ? "expanded" : "collapsed")
        )
        .accessibilityIdentifier("agent.\(agent.id)")
    }

    private func agentStatusSymbol(_ status: AgentOverview.Status) -> String {
        switch status {
        case .active: "circle"
        case .paused: "pause.circle.fill"
        case .stopped, .missingTrigger: "exclamationmark.triangle.fill"
        case .failing: "exclamationmark.circle.fill"
        case .fired: "checkmark.circle.fill"
        }
    }

    private func emptyState(snapshot: SessionCatalogSnapshot) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.locus(size: 18))
                .foregroundStyle(LocusTheme.muted)
            Text(snapshot.searchQuery.isEmpty
                ? "No saved sessions yet" : "No matching sessions")
                .font(.locus(size: 10, weight: .semibold))
            if snapshot.searchQuery.isEmpty {
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

    private func agentEmptyState(snapshot: SessionCatalogSnapshot) -> some View {
        VStack(spacing: 9) {
            Image(locusSymbol: LocusSymbol.robot)
                .font(.locus(size: 18))
                .foregroundStyle(LocusTheme.muted)
            Text(snapshot.searchQuery.isEmpty ? "No agents yet" : "No matching agents")
                .font(.locus(size: 10, weight: .semibold))
            if snapshot.searchQuery.isEmpty {
                Text("Configure an agent to give it its own ongoing chats.")
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
    private func footer(snapshot: SessionCatalogSnapshot) -> some View {
        VStack(spacing: 8) {
            if model.sidebarDestination == .ask {
                workspaceMenu(snapshot: snapshot)
            } else {
                HStack(spacing: SidebarMetrics.iconGap) {
                    Image(locusSymbol: LocusSymbol.robot)
                        .font(.locus(size: 11, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .frame(width: SidebarMetrics.iconColumn)
                    Text("Agents")
                        .font(.locus(size: 10, weight: .semibold))
                    Spacer()
                    Text("\(agentCount(snapshot: snapshot))")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                .foregroundStyle(LocusTheme.inkSoft)
                .padding(.horizontal, SidebarMetrics.rowInset)
                .frame(height: 34)
                .background(LocusTheme.white.opacity(0.56))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Agents")
                .accessibilityValue(
                    "\(agentCount(snapshot: snapshot)) agents, "
                        + "\(snapshot.agentSessions.count) chats"
                )
            }

            HStack {
                agentStatus
                Spacer()
                settingsMenu(snapshot: snapshot)
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func settingsMenu(snapshot: SessionCatalogSnapshot) -> some View {
        Menu {
            Button("Settings…") { model.presentSettings() }
                .accessibilityIdentifier("sidebar.settings")
            Button("Usage & Costs…") { model.usageDashboardPresented = true }
                .accessibilityIdentifier("sidebar.usage")
            Button("Session Checkpoints…") { model.checkpointPresented = true }
                .accessibilityIdentifier("sidebar.checkpoints")
            Button("Notebook…") { model.notebookPresented = true }
                .accessibilityIdentifier("sidebar.notebook")
            Divider()
            Button("Archived Sessions") {
                model.setShowArchived(!snapshot.showArchivedSessions)
            }
            .accessibilityValue(
                snapshot.showArchivedSessions ? "Shown" : "Hidden"
            )
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

    private func workspaceMenu(snapshot: SessionCatalogSnapshot) -> some View {
        Menu {
            Button("Choose Workspace…") { model.chooseWorkspace() }
            Button("New Workspace…") { model.createWorkspace() }
                .accessibilityIdentifier("workspace.new")
            Button("Reveal in Finder") { model.openWorkspaceInFinder() }
            if !snapshot.recentWorkspaceProfiles.isEmpty {
                Divider()
                Section("Recent Workspaces") {
                    ForEach(snapshot.recentWorkspaceProfiles) { profile in
                        let isAvailable = snapshot.workspaceAvailabilityByProfileID[profile.id]
                            == true
                        Button {
                            model.switchWorkspace(to: profile.path)
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: isAvailable ? "folder" : "exclamationmark.triangle"
                            )
                        }
                        .disabled(!isAvailable)
                        .accessibilityIdentifier("workspace.profile.\(profile.path)")
                    }
                }
                if snapshot.recentWorkspaceProfiles.contains(where: {
                    snapshot.workspaceAvailabilityByProfileID[$0.id] != true
                }) {
                    Button("Remove Missing Entries") {
                        for profile in snapshot.recentWorkspaceProfiles where
                            snapshot.workspaceAvailabilityByProfileID[profile.id] != true
                        {
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
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var teamRunLive: TeamRunLiveModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
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
                Text(agentTeams.selectedAgentTeam?.name ?? "Team")
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
        let activity = teamRunLive.dispatcherActivity
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
               teamRunLive.agentActivities.isEmpty
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
                Text("\(completedJobs)/\(teamRunLive.agentActivities.count)")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            if teamRunLive.agentActivities.isEmpty {
                Text(model.orchestrationState == nil
                    ? "No run yet. Send a task with this team selected."
                    : "Jobs appear here after the dispatcher returns a plan.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(teamRunLive.agentActivities) { activity in
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
            Text("\(teamRunLive.teamModelCalls.formatted()) calls")
            Text("\(teamRunLive.teamMeteredTokens.formatted()) hosted tokens")
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
        guard let id = agentTeams.selectedAgentTeam?.dispatcherID else { return nil }
        return agentTeams.agentProfiles.first(where: { $0.id == id })
    }

    private var teamProfiles: [AgentProfile] {
        guard let team = agentTeams.selectedAgentTeam else { return [] }
        return team.memberIDs.compactMap { id in agentTeams.agentProfiles.first(where: { $0.id == id }) }
    }

    private var completedJobs: Int {
        teamRunLive.agentActivities.filter { $0.state == .completed }.count
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
        let durable = runs.orchestrationRuns.first(where: { $0.id == runID })
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
            provider = providerAccounts.providerAccounts.first(where: { $0.id == id })?.displayName
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

private func handleChatSidebarDrop(
    _ providers: [NSItemProvider],
    model: AppModel,
    targetFolderID: String?,
    index: Int?,
    targetWorkspace: String? = nil
) -> Bool {
    guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
    }) else { return false }
    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
        item, _ in
        let value: String?
        if let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        } else if let text = item as? String {
            value = text
        } else if let text = item as? NSString {
            value = text as String
        } else {
            value = nil
        }
        guard let value else { return }
        Task { @MainActor in
            if value.hasPrefix("locus-chat:") {
                let id = String(value.dropFirst("locus-chat:".count))
                guard let session = model.sessions.first(where: { $0.id == id }) else { return }
                if let targetWorkspace,
                   session.workspacePath != SessionSummary.canonicalWorkspacePath(targetWorkspace) {
                    model.showToast("Chats stay inside their workspace")
                    return
                }
                model.moveChat(session, to: targetFolderID, index: index)
            } else if value.hasPrefix("locus-folder:") {
                let id = String(value.dropFirst("locus-folder:".count))
                guard let folder = model.chatFolders.first(where: { $0.id == id }) else { return }
                if let targetWorkspace,
                   SessionSummary.canonicalWorkspacePath(folder.workspace)
                    != SessionSummary.canonicalWorkspacePath(targetWorkspace) {
                    model.showToast("Folders stay inside their workspace")
                    return
                }
                model.moveChatFolder(folder, to: targetFolderID, index: index)
            }
        }
    }
    return true
}

private struct ChatSidebarDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let targetFolderID: String?
    let index: Int?
    let targetWorkspace: String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted {
                    Capsule()
                        .fill(LocusTheme.signalDeep)
                        .frame(height: 2)
                        .padding(.horizontal, 5)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
                handleChatSidebarDrop(
                    providers,
                    model: model,
                    targetFolderID: targetFolderID,
                    index: index,
                    targetWorkspace: targetWorkspace
                )
            }
    }
}

private struct ChatFolderBranchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let node: SessionSidebarFolderSnapshot
    let depth: Int
    let onCreateFolder: (String, String?) -> Void
    let onRenameFolder: (ChatFolderRecord) -> Void
    let onDeleteFolder: (ChatFolderRecord) -> Void
    let sessionContent: (SessionSummary) -> AnyView
    @State private var isDropTarget = false
    @State private var hoverExpansion: Task<Void, Never>?

    private var folder: ChatFolderRecord { node.folder }

    var body: some View {
        let snapshot = sessionCatalog.snapshot
        let expanded = !snapshot.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || snapshot.expandedChatFolderIDs.contains(folder.id)
        VStack(spacing: 2) {
            Button {
                withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                    model.setChatFolderExpanded(folder.id, expanded: !expanded)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.locus(size: 8, weight: .semibold))
                        .frame(width: 10)
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.locus(size: 11, weight: .medium))
                        .foregroundStyle(isDropTarget ? LocusTheme.signalDeep : LocusTheme.muted)
                    Text(folder.name)
                        .font(.locus(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(node.chats.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                .foregroundStyle(LocusTheme.inkSoft)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(isDropTarget ? LocusTheme.signal.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .padding(.leading, 18 + CGFloat(depth) * 14)
            .contextMenu {
                Button("New Subfolder…") { onCreateFolder(folder.workspace, folder.id) }
                Button("Rename…") { onRenameFolder(folder) }
                Menu("Move to Folder") {
                    Button("Workspace Root") { model.moveChatFolder(folder, to: nil) }
                        .disabled(folder.parentID == nil)
                    ForEach(snapshot.folderMoveTargetsByFolderID[folder.id] ?? []) { target in
                        Button(target.name) { model.moveChatFolder(folder, to: target.id) }
                            .disabled(folder.parentID == target.id)
                    }
                }
                Button("Move Earlier") { model.reorderChatFolder(folder, offset: -1) }
                Button("Move Later") { model.reorderChatFolder(folder, offset: 1) }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    onDeleteFolder(folder)
                }
            }
            .onDrag { NSItemProvider(object: "locus-folder:\(folder.id)" as NSString) }
            .onDrop(of: [.plainText], isTargeted: $isDropTarget) { providers in
                handleChatSidebarDrop(
                    providers,
                    model: model,
                    targetFolderID: folder.id,
                    index: nil,
                    targetWorkspace: folder.workspace
                )
            }
            .onChange(of: isDropTarget) { _, targeted in
                hoverExpansion?.cancel()
                guard targeted, !expanded else { return }
                hoverExpansion = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, isDropTarget else { return }
                    withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                        model.setChatFolderExpanded(folder.id, expanded: true)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isDropTarget {
                    Capsule()
                        .fill(LocusTheme.signalDeep)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Folder \(folder.name)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chatFolder.\(folder.id)")
            .accessibilityAction(named: "Move Earlier") {
                model.reorderChatFolder(folder, offset: -1)
            }
            .accessibilityAction(named: "Move Later") {
                model.reorderChatFolder(folder, offset: 1)
            }

            if expanded {
                ForEach(node.children) { child in
                    ChatFolderBranchView(
                        node: child,
                        depth: depth + 1,
                        onCreateFolder: onCreateFolder,
                        onRenameFolder: onRenameFolder,
                        onDeleteFolder: onDeleteFolder,
                        sessionContent: sessionContent
                    )
                    .environmentObject(model)
                }
                ForEach(node.chats) { session in
                    sessionContent(session)
                        .padding(.leading, 32 + CGFloat(depth) * 14)
                }
            }
        }
    }
}

private struct WorkspaceGroupRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var newChatFocused: Bool
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
                    .frame(width: 16, height: 28)
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
                    Text(group.title)
                        .font(.locus(size: 10, weight: .medium))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text("\(group.chats.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityLabel("\(group.chats.count) \(group.chats.count == 1 ? "chat" : "chats")")
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
                        .foregroundStyle(
                            isHovering || newChatFocused ? LocusTheme.muted : Color.clear
                        )
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .focused($newChatFocused)
                .disabled(actionsDisabled || !group.isAvailable)
                .help("New chat in \(group.title)")
                .accessibilityLabel("New chat in \(group.title)")
                .accessibilityIdentifier("workspace.group.\(group.id).newChat")
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 34)
        .background(active ? LocusTheme.paperDeep.opacity(0.62) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LocusMotion.press, value: isHovering || newChatFocused)
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
    let showsAgentIcon: Bool
    let action: () -> Void

    private var showsActivity: Bool { isRunning || teamState != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if session.isAgentChat && showsAgentIcon {
                    Image(locusSymbol: LocusSymbol.robot)
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.locus(size: 10, weight: isActive ? .medium : .regular))
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
            .frame(height: showsActivity ? 38 : 30)
            .background(isActive ? LocusTheme.paperDeep.opacity(0.56) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
