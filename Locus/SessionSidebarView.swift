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

struct AgentSidebarGroupModel: Identifiable {
    let id: String
    let reference: AgentInspectorAgent?
    let accessibilityID: String
    let name: String
    let tasks: [SessionSummary]
    let totalChatCount: Int
    let definition: AgentDefinition?
    let runningChatCount: Int
    let sourceNeedsAttention: Bool
    var profileID: UUID? = nil
    var profile: AgentProfile? = nil

    var isUnavailableSavedAgent: Bool { profileID != nil && profile == nil }
    var status: AgentOverview.Status { profile != nil ? .active : AgentOverview.status(for: definition) }
    var needsAttention: Bool { status.isWarning || sourceNeedsAttention }
    var statusTitle: String {
        if profile != nil { return sourceNeedsAttention ? "Needs attention" : runningChatCount > 0 ? "Working" : "Ready" }
        return AgentInspectorCopy.agentStatusTitle(status, vocabulary: definition?.vocabulary ?? .events,
            isRunning: runningChatCount > 0, sourceNeedsAttention: sourceNeedsAttention)
    }
}

/// Build the hierarchy from agent definitions, not only their chats. Search
/// an agent name to see its conversations, or a chat title to see its owner.
/// Typed identities keep an event and schedule with the same storage ID apart.
enum AgentSidebarCatalog {
    static func groups(
        definitions: [AgentDefinition], sessions: [SessionSummary], query: String,
        showArchived: Bool, runningSessionIDs: Set<String>,
        connections: [ConnectorConnection] = [], connectionsLoaded: Bool = false,
        profiles: [AgentProfile] = [], recentAgentIDs: [String] = []
    ) -> [AgentSidebarGroupModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileChats = sessions.filter { $0.savedAgentProfileID != nil && (showArchived || !$0.isArchived) }
        let profileIDs = Set(profiles.map(\.id)).union(profileChats.compactMap(\.savedAgentProfileID))
        let savedGroups = profileIDs.compactMap { profileID -> AgentSidebarGroupModel? in
            let profile = profiles.first { $0.id == profileID }
            let tasks = profileChats.filter { $0.savedAgentProfileID == profileID }.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                return $0.id < $1.id
            }
            let name = profile?.name ?? "Unavailable agent"
            let nameMatches = query.isEmpty || name.localizedCaseInsensitiveContains(query)
            let matches = nameMatches ? tasks : tasks.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
            guard nameMatches || !matches.isEmpty else { return nil }
            let ownedReferences = Set(sessions.filter { $0.savedAgentProfileID == profileID }
                .compactMap { $0.agentReference(in: definitions)?.id })
            let needsAttention = definitions.filter { ownedReferences.contains(AgentInspectorAgent($0).id) }
                .contains { definition in
                    AgentOverview.status(for: definition).isWarning || sourceNeedsAttention(
                        definition: definition,
                        connection: definition.trigger.flatMap { trigger in connections.first { $0.id == trigger.connectionID } },
                        connectionsLoaded: connectionsLoaded)
                }
            return AgentSidebarGroupModel(id: "profile:\(profileID.uuidString)", reference: nil,
                accessibilityID: profileID.uuidString, name: name, tasks: matches, totalChatCount: tasks.count,
                definition: nil, runningChatCount: tasks.filter { runningSessionIDs.contains($0.id) }.count,
                sourceNeedsAttention: needsAttention, profileID: profileID, profile: profile)
        }
        // A saved agent owns its automation chats too; do not repeat those
        // configurations as unrelated agents beside their parent.
        let ownedDefinitions = Set(sessions.filter { $0.savedAgentProfileID != nil }
            .compactMap { $0.agentReference(in: definitions)?.id })
        let chats = sessions.filter { $0.isAgentChat && $0.savedAgentProfileID == nil && (showArchived || !$0.isArchived) }
        let byAgent = Dictionary(grouping: chats) {
            $0.agentReference(in: definitions)?.id ?? "unassigned:\($0.id)"
        }
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map {
            (AgentInspectorAgent($0).id, $0)
        })
        let identities = Set(definitionsByID.keys).subtracting(ownedDefinitions).union(byAgent.keys)
        let automatedGroups = identities.compactMap { identity -> AgentSidebarGroupModel? in
            let definition = definitionsByID[identity]
            let tasks = (byAgent[identity] ?? []).sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                return $0.id < $1.id
            }
            let reference = definition.map(AgentInspectorAgent.init)
                ?? tasks.first?.agentReference(in: definitions)
            let rawID = reference?.agentID ?? tasks.first?.agentTriggerID ?? identity
            let hasCollision = definitions.filter { $0.id == rawID }.count > 1
            let name = definition?.name.nilIfBlank
                ?? tasks.compactMap(\.agentName).first?.nilIfBlank
                ?? tasks.first?.displayTitle ?? "Unavailable agent"
            let nameMatches = query.isEmpty || name.localizedCaseInsensitiveContains(query)
            let matches = nameMatches ? tasks : tasks.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
            }
            guard nameMatches || !matches.isEmpty else { return nil }
            return AgentSidebarGroupModel(
                id: identity, reference: reference,
                accessibilityID: hasCollision ? identity : rawID,
                name: name, tasks: matches, totalChatCount: tasks.count,
                definition: definition,
                runningChatCount: tasks.filter { runningSessionIDs.contains($0.id) }.count,
                sourceNeedsAttention: sourceNeedsAttention(
                    definition: definition,
                    connection: definition?.trigger.flatMap { trigger in connections.first { $0.id == trigger.connectionID } },
                    connectionsLoaded: connectionsLoaded
                )
            )
        }
        let recentRanks = Dictionary(recentAgentIDs.enumerated().map { ($0.element, $0.offset) },
                                     uniquingKeysWith: min)
        return (savedGroups + automatedGroups).sorted {
            let lhsRank = recentRanks[$0.id] ?? Int.max
            let rhsRank = recentRanks[$1.id] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    static func sourceNeedsAttention(
        definition: AgentDefinition?, connection: ConnectorConnection?, connectionsLoaded: Bool
    ) -> Bool {
        // Before the connection store has answered, absence is unknown rather
        // than proof that an Agent's source was removed.
        guard connection != nil || connectionsLoaded else { return false }
        return AgentInspectorCopy.sourceNeedsAttention(definition: definition, connection: connection)
    }
}

#if DEBUG
/// A metadata-only probe for the compact sidebar's native hit ownership.
/// It never forces layout, exposes content, synthesizes input, or consumes an
/// event. The opt-in fixture run is the only place it installs a monitor.
private struct SidebarHitTestDiagnostics: NSViewRepresentable {
    static let isEnabled = {
        let environment = ProcessInfo.processInfo.environment
        return environment["LOCUS_UI_TESTING"] == "1"
            && environment["LOCUS_UI_TESTING_SIDEBAR_HIT_TEST"] == "1"
    }()

    func makeNSView(context: Context) -> SidebarHitTestDiagnosticView {
        SidebarHitTestDiagnosticView(frame: .zero)
    }

    func updateNSView(_ view: SidebarHitTestDiagnosticView, context: Context) {}
}

private final class SidebarHitTestDiagnosticView: NSView {
    private let enabled = SidebarHitTestDiagnostics.isEnabled
    private var eventMonitor: Any?
    private var geometryObservers: [NSObjectProtocol] = []
    private var recordCount = 0
    private var layoutRecordPending = false
    private var lastReportedGeometry: [NSRect]?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observeAncestorGeometry()
        guard enabled, window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let scroll = self.enclosingScrollView,
                  event.window === self.window,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            else { return event }
            let kind = event.type == .scrollWheel ? "wheel"
                : (event.type == .rightMouseDown ? "rightMouseDown" : "leftMouseDown")
            self.record(kind, eventPoint: event.locationInWindow)
            return event
        }
        scheduleRecord("attached")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeAncestorGeometry()
    }

    private func observeAncestorGeometry() {
        let center = NotificationCenter.default
        geometryObservers.forEach(center.removeObserver)
        geometryObservers.removeAll()
        guard enabled, let window else { return }
        var ancestor = superview
        for _ in 0..<32 {
            guard let view = ancestor else { break }
            view.postsFrameChangedNotifications = true
            geometryObservers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRecord("ancestor.frameChanged") }
            })
            ancestor = view.superview
        }
        // SwiftUI may animate a hosting boundary without laying out this
        // stationary document again. Sample changed geometry at a real window
        // update, including the final frame; never wait on a synthetic timer.
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRecord("window.updated") }
        })
    }

    override func layout() {
        super.layout()
        scheduleRecord("layout")
    }

    private func scheduleRecord(_ event: String) {
        guard enabled, !layoutRecordPending, recordCount < 64 else { return }
        layoutRecordPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutRecordPending = false
            self.record(event)
        }
    }

    private func record(_ event: String, eventPoint: NSPoint? = nil) {
        guard enabled, recordCount < 64, let window,
              let root = window.contentView, let scroll = enclosingScrollView
        else { return }
        let geometry = [
            scroll.convert(scroll.bounds, to: nil), scroll.contentView.bounds,
            scroll.documentView?.frame ?? .zero, scroll.documentView?.bounds ?? .zero,
        ]
        guard eventPoint != nil || geometry != lastReportedGeometry else { return }
        lastReportedGeometry = geometry
        recordCount += 1
        func rect(_ value: NSRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        func belongs(_ view: NSView?, to ancestor: NSView?) -> Bool {
            guard let ancestor else { return false }
            var current = view
            for _ in 0..<64 {
                guard let view = current else { return false }
                if view === ancestor { return true }
                current = view.superview
            }
            return false
        }
        func hitMetadata(at point: NSPoint) -> [String: Any] {
            // NSView.hitTest takes its argument in its superview's space.
            let hitPoint = root.superview?.convert(point, from: nil) ?? point
            let hit = root.hitTest(hitPoint)
            let role: String
            switch hit {
            case is NSScrollView: role = "NSScrollView"
            case is NSClipView: role = "NSClipView"
            case is NSTextView: role = "NSTextView"
            case is NSControl: role = "NSControl"
            case .none: role = "none"
            default: role = "NSView"
            }
            var metadata: [String: Any] = [
                "pointInWindow": [Double(point.x), Double(point.y)],
                "nativeRole": role,
                "insideSidebarScroll": belongs(hit, to: scroll),
                "insideSidebarDocument": belongs(hit, to: scroll.documentView),
                "nativeIsCompactHost": hit is CompactSidebarHostingView,
                "nativeIsSidebarScroll": hit === scroll,
                "nativeIsSidebarDocument": hit === scroll.documentView,
            ]
            if let hit { metadata["nativeFrameInWindow"] = rect(hit.convert(hit.bounds, to: nil)) }
            // Compare point-based public AX routing at each native boundary.
            // Do not enumerate virtual descendants or log labels/identifiers.
            func accessibilityRole(_ element: Any?) -> String {
                guard let accessible = element as? any NSAccessibilityProtocol,
                      let role = accessible.accessibilityRole() else { return "none" }
                switch role {
                case .button: return "button"
                case .scrollArea: return "scrollArea"
                case .group: return "group"
                case .textField: return "textField"
                case .textArea: return "textArea"
                case .staticText: return "staticText"
                default: return "other"
                }
            }
            let screenPoint = window.convertPoint(toScreen: point)
            metadata["rootAXRole"] = accessibilityRole(root.accessibilityHitTest(screenPoint))
            metadata["scrollAXRole"] = accessibilityRole(scroll.accessibilityHitTest(screenPoint))
            metadata["documentAXRole"] = accessibilityRole(scroll.documentView?.accessibilityHitTest(screenPoint))
            var ancestor: NSView? = scroll
            for _ in 0..<64 {
                guard let view = ancestor else { break }
                if let host = view as? CompactSidebarHostingView {
                    metadata["compactHostAXRole"] = accessibilityRole(host.accessibilityHitTest(screenPoint))
                    break
                }
                ancestor = view.superview
            }
            return metadata
        }
        let clip = scroll.contentView
        var samples: [[String: Any]] = []
        for y in [0.04, 0.5, 0.98] {
            for x in [0.15, 0.5, 0.8] {
                let point = NSPoint(x: clip.bounds.minX + clip.bounds.width * x,
                                    y: clip.bounds.minY + clip.bounds.height * y)
                samples.append(hitMetadata(at: clip.convert(point, to: nil)))
            }
        }
        var record: [String: Any] = [
            "event": event, "record": recordCount,
            "windowContentSize": [Double(window.contentLayoutRect.width),
                                  Double(window.contentLayoutRect.height)],
            "scrollFrameInWindow": rect(scroll.convert(scroll.bounds, to: nil)),
            "clipBounds": rect(clip.bounds), "samples": samples,
        ]
        if let document = scroll.documentView {
            record["documentFrame"] = rect(document.frame)
            record["documentBounds"] = rect(document.bounds)
        }
        if let eventPoint { record["eventHit"] = hitMetadata(at: eventPoint) }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? FileHandle.standardError.write(contentsOf: Data(
                ("LocusSidebarHitTest " + json + "\n").utf8
            ))
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif

/// Cross-session transcript results observe their child model at the smallest
/// owning boundary, so result updates do not invalidate the whole sidebar or AppModel.
private struct TranscriptHitsSection: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                        .foregroundStyle(viewColors.muted)
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
                    .foregroundStyle(viewColors.muted)
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
                        .foregroundStyle(viewColors.muted)
                    Text(hit.title?.nilIfEmpty ?? "Untitled chat")
                        .font(.locus(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(
                        Date(timeIntervalSince1970: hit.mtime)
                            .formatted(.relative(presentation: .named))
                    )
                    .font(.locus(size: 7))
                    .foregroundStyle(viewColors.muted)
                }
                Text(highlightedSnippet(hit))
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.muted)
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
            text[range].foregroundColor = viewColors.signalDeep
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
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdateController
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sessionToRename: SessionSummary?
    @State private var renameText = ""
    @State private var workspaceToRemove: WorkspaceChatGroup?
    @State private var folderToDelete: ChatFolderRecord?
    @State private var folderEditor: ChatFolderEditorRequest?
    @State private var folderEditorName = ""
    @State private var agentToDelete: AgentDefinition?
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let snapshot = sessionCatalog.snapshot
        VStack(spacing: 0) {
            header
            controls

            Button { model.openLibrary() } label: {
                Label("Library", systemImage: "books.vertical")
                    .font(.locus(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier("sidebar.library")

            Button { model.identityVault.open() } label: {
                Label("Identity Vault", systemImage: "person.text.rectangle")
                    .font(.locus(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier("sidebar.identityVault")

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    sectionHeader(snapshot: snapshot)
                    if searchExpanded || (model.sidebarDestination == .agents && model.agentDefinitions.count > 8) {
                        searchField(snapshot: snapshot)
                            .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
                    }
                    if model.sidebarDestination == .agents {
                        AgentSidebarSection(
                            crew: model.agentCrewChat,
                            automation: model.eventAutomations,
                            snapshot: snapshot,
                            confirmDelete: { agentToDelete = $0 },
                            sessionContent: { session in
                                AnyView(sessionRow(session, snapshot: snapshot))
                            }
                        )
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
                                            .foregroundStyle(viewColors.muted)
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
                .background {
                    #if DEBUG
                    if SidebarHitTestDiagnostics.isEnabled {
                        SidebarHitTestDiagnostics()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    #endif
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("sidebar.scroll")
            .accessibilityLabel(
                model.sidebarDestination == .agents ? "Agents and chats" : "Workspaces and chats"
            )
            .task(id: sessionCatalog.sessionReveal?.id) {
                guard let request = sessionCatalog.sessionReveal else { return }
                defer { sessionCatalog.finishSessionReveal(request.id) }
                // Let the destination's expanded group and folder rows lay out.
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                withAnimation(reduceMotion ? nil : LocusMotion.scroll) {
                    proxy.scrollTo("sidebar.session.\(request.sessionID)", anchor: .center)
                }
            }
            }

            footer(snapshot: snapshot)
        }
        .frame(maxHeight: .infinity)
        .locusSurface(.structural)
        .background {
            // Content remains below the traffic lights, while its structural
            // material fills the otherwise mismatched title-bar corner.
            viewColors.surfaceStructural
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
                if let agentToDelete { model.deleteAgent(agentToDelete) }
                agentToDelete = nil
            }
            .accessibilityIdentifier("agent.delete.confirm")
            Button("Cancel", role: .cancel) { agentToDelete = nil }
        } message: {
            Text(agentToDelete?.isSchedule == true
                ? "It stops running on its schedule. Its chats stay where they are."
                : "It stops listening for events. Its chats stay where they are.")
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
                .foregroundStyle(viewColors.ink)
                .accessibilityIdentifier("sidebar.brand")

            Spacer(minLength: 4)

            Button {
                withAnimation(LocusMotion.spatial) {
                    model.sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.locus(size: 13, weight: .medium))
                    .foregroundStyle(viewColors.muted)
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
                    model.switchSidebarDestination(destination)
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

            navigationRow(
                symbol: "puzzlepiece.extension",
                title: "Manage Plugins",
                help: "Manage plugins, MCP servers, and skills",
                accessibilityLabel: "Manage Plugins",
                identifier: "sidebar.extensions"
            ) {
                model.presentSettings(.extensions)
            }

            primaryCreationButton

            HStack(spacing: 7) {
                if model.sidebarDestination == .agents {
                    secondaryButton(
                        symbol: "gearshape.2",
                        title: "Manage Agents",
                        help: "Create agents, manage their triggers and access, and inspect activity",
                        accessibilityLabel: "Manage Agents",
                        identifier: "sidebar.configureAgent"
                    ) {
                        model.presentConfigureAgent(draftText: model.draftText)
                    }
                } else {
                    secondaryButton(
                        symbol: "book.closed",
                        title: "Notebook",
                        help: "Open your notebook",
                        accessibilityLabel: "Notebook",
                        identifier: "sidebar.openNotebook"
                    ) {
                        model.notebookPresented = true
                    }
                }

                activityButton
            }
        }
        .padding(.horizontal, SidebarMetrics.gutter)
        .padding(.bottom, 12)
    }

    /// The primary action creates a saved agent in Agent, or a chat in Work.
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
                    .foregroundStyle(viewColors.paper.opacity(0.75))
            }
            .font(.locus(size: 11, weight: .semibold))
            .foregroundStyle(viewColors.paper)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(viewColors.ink)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .help(isAgents
            ? "Create a saved agent and its first chat (⌘N)"
            : "Start a new chat (⌘N)")
        .accessibilityLabel(isAgents ? "New agent" : "New chat")
        .accessibilityValue(isAgents ? "Saved agent" : "Standard chat")
        .accessibilityIdentifier("sidebar.newSession")
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
                    ? viewColors.accentAction : viewColors.inkSoft)
                .frame(width: 36, height: 36)
                .background(activityCenter.activityCenterPresented
                    ? viewColors.signal.opacity(0.12)
                    : viewColors.white.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(viewColors.line, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    if activityCenter.activityNeedsAttentionCount > 0 {
                        Text("\(activityCenter.activityNeedsAttentionCount)")
                            .font(.locus(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(viewColors.dangerForeground)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(viewColors.surfaceCard)
                            .overlay {
                                Capsule().stroke(viewColors.dangerForeground.opacity(0.35), lineWidth: 1)
                            }
                            .clipShape(Capsule())
                            .offset(x: 4, y: -4)
                            .accessibilityIdentifier("sidebar.activity.badge")
                    } else if activityCenter.unreadResultCount > 0 {
                        Circle()
                            .fill(viewColors.accentAction)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().stroke(viewColors.surfaceCard, lineWidth: 2) }
                            .offset(x: 2, y: -2)
                            .accessibilityIdentifier("sidebar.activity.unread")
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
                : activityCenter.unreadResultCount > 0
                    ? "\(activityCenter.unreadResultCount) unread results"
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
            .foregroundStyle(viewColors.inkSoft)
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
            .foregroundStyle(viewColors.inkSoft)
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(viewColors.white.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(viewColors.line, lineWidth: 1)
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
                    .foregroundStyle(searchExpanded ? viewColors.ink : viewColors.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.locus(.icon))
            .help(model.sidebarDestination == .agents ? "Search agents and chats (⇧⌘F)" : "Search sessions (⇧⌘F)")
            .accessibilityLabel(model.sidebarDestination == .agents ? "Search agents and chats" : "Search sessions")
            .accessibilityValue(searchExpanded ? "Shown" : "Hidden")
            .accessibilityIdentifier("sidebar.search.toggle")
            if model.sidebarDestination == .agents {
                Button { model.presentNewAgent() } label: {
                    Image(systemName: "plus")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.locus(.icon))
                .help("Create an agent")
                .accessibilityLabel("Create an agent")
                .accessibilityIdentifier("sidebar.newAgent")
            }
            if model.sidebarDestination == .ask {
                Button {
                    requestFolderEditor(
                        workspace: snapshot.activeWorkspaceID,
                        parentID: nil
                    )
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
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
                .foregroundStyle(viewColors.muted)
            TextField(model.sidebarDestination == .agents ? "Search agents and chats" : "Search sessions", text: Binding(
                get: { snapshot.searchQuery },
                set: { sessionCatalog.setSearchQuery($0) }
            ))
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .focused($searchFocused)
                .accessibilityIdentifier("sidebar.search")
            if !snapshot.searchQuery.isEmpty {
                Button {
                    sessionCatalog.setSearchQuery("")
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.locus())
                .foregroundStyle(viewColors.muted)
                .accessibilityLabel("Clear session search")
                .accessibilityIdentifier("sidebar.search.clear")
            }
        }
        .padding(.horizontal, SidebarMetrics.rowInset)
        .frame(height: 32)
        .background(viewColors.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(viewColors.line, lineWidth: 1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        // Escape leaves the way it arrived: empty query, field put away.
        .onExitCommand {
            sessionCatalog.setSearchQuery("")
            withAnimation(LocusMotion.spatial) { searchExpanded = false }
        }
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
        .id("sidebar.session.\(session.id)")
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
            if model.chatHasClearableWarning(session) {
                Button(model.isClearingChatWarning(session)
                    ? "Clearing Warning…" : "Clear Warning") {
                    model.clearChatWarning(session)
                }
                .disabled(model.isClearingChatWarning(session))
                .accessibilityIdentifier("session.\(session.id).clearWarning")
            }
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
            if let owner = model.agentOwningEventChat(session) {
                Text("Receives \(owner.name)'s \(owner.vocabulary.arrivals)"
                    + " — delete the agent to remove it")
            }
            Button("Delete Chat", role: .destructive) {
                model.deleteChat(session)
            }
            .disabled(
                model.isBusy || model.hasPendingPermission || model.chatHasActiveRun(session)
                    || model.agentOwningEventChat(session) != nil
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

    private func emptyState(snapshot: SessionCatalogSnapshot) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.locus(size: 18))
                .foregroundStyle(viewColors.muted)
            Text(snapshot.searchQuery.isEmpty
                ? "No saved sessions yet" : "No matching sessions")
                .font(.locus(size: 10, weight: .semibold))
            if snapshot.searchQuery.isEmpty {
                Text("Start a conversation and it will appear here.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.muted)
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
                AgentSelectionMenu()
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
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
    }

    private func settingsMenu(snapshot: SessionCatalogSnapshot) -> some View {
        Menu {
            Button("Settings…") { model.presentSettings() }
                .accessibilityIdentifier("sidebar.settings")
            if updates.isAvailable {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityIdentifier("sidebar.checkForUpdates")
            } else {
                Button("Software Updates…") { model.presentSettings(.updates) }
                    .accessibilityIdentifier("sidebar.softwareUpdates")
            }
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
                .foregroundStyle(viewColors.muted)
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
                    .foregroundStyle(viewColors.muted)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("sidebar.workspaceIcon")
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(viewColors.ink)
                        .lineLimit(1)
                    Text("Workspace")
                        .font(.locus(size: 8))
                        .foregroundStyle(viewColors.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(viewColors.muted)
            }
            .padding(.horizontal, SidebarMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 40)
            .background(viewColors.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(viewColors.line, lineWidth: 1)
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

    /// Chooses the saved agent that owns the next chat, the way the Work
    /// footer's workspace menu chooses the folder. Tasks stay in the sidebar
    /// list, where their activity and settings live.
    private struct AgentSelectionMenu: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

        @EnvironmentObject private var model: AppModel
        @EnvironmentObject private var agentTeams: AgentTeamsModel
        @State private var isPresented = false
        @State private var query = ""
        @State private var focusedProfileID: AgentProfile.ID?
        @FocusState private var searchFocused: Bool

        private static let rowHeight: CGFloat = 46
        private static let rowSpacing: CGFloat = 2
        private static let visibleRows = 6

        private var profiles: [AgentProfile] { agentTeams.agentProfiles }
        private var filteredProfiles: [AgentProfile] {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return profiles }
            return profiles.filter {
                $0.name.localizedCaseInsensitiveContains(text)
                    || $0.specialtyTitle.localizedCaseInsensitiveContains(text)
                    || $0.model.localizedCaseInsensitiveContains(text)
            }
        }
        private var selectedProfile: AgentProfile? { model.selectedSavedAgentProfile }
        private var selectedName: String { selectedProfile?.name ?? "Choose an agent" }
        private var selectedContext: String { selectedProfile.map(Self.subtitle) ?? "For your next conversation" }
        private var countLabel: String { profiles.count == 1 ? "1 agent" : "\(profiles.count) agents" }

        private static func subtitle(_ profile: AgentProfile) -> String {
            let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? profile.specialtyTitle : "\(profile.specialtyTitle) · \(model)"
        }

        private func agentTile(side: CGFloat, glyph: CGFloat) -> some View {
            Image(locusSymbol: LocusSymbol.robot)
                .font(.locus(size: glyph, weight: .semibold))
                .foregroundStyle(viewColors.accentAction)
                .frame(width: side, height: side)
                .background(viewColors.accentAction.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }

        var body: some View {
            Button {
                query = ""
                focusedProfileID = selectedProfile?.id
                isPresented.toggle()
            } label: {
                HStack(spacing: 9) {
                    if let profile = selectedProfile {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 27)
                    } else {
                        agentTile(side: 27, glyph: 13).accessibilityIdentifier("sidebar.agentIcon")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedName)
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(viewColors.ink)
                            .lineLimit(1)
                        Text(selectedContext)
                            .font(.locus(size: 8))
                            .foregroundStyle(viewColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
                .background(viewColors.white.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isPresented ? viewColors.accentAction.opacity(0.4) : viewColors.line,
                                lineWidth: 1)
                }
            }
            .buttonStyle(.locus())
            .help("Choose an agent to open its chats")
            .accessibilityLabel("Agents menu")
            .accessibilityValue("\(selectedName), \(selectedContext), \(countLabel)")
            .accessibilityIdentifier("sidebar.agentMenu")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) { picker }
        }

        private var picker: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Choose an agent")
                        .font(.locus(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(profiles.count)")
                        .font(.locus(size: 10, design: .monospaced))
                        .foregroundStyle(viewColors.textSecondary)
                        .accessibilityLabel(countLabel)
                }
                .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
                searchField
                if filteredProfiles.isEmpty { emptyState } else { profileList }
                Rectangle().fill(viewColors.line).frame(height: 1)
                Text("Choose an agent to open its chats.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                HStack(spacing: 8) {
                    Button {
                        isPresented = false
                        model.presentNewAgent()
                    } label: {
                        Label("New agent", systemImage: "plus")
                            .foregroundStyle(viewColors.accentAction)
                    }
                    .accessibilityIdentifier("agent.menu.new")
                    Spacer()
                    Button {
                        isPresented = false
                        model.presentConfigureAgent(draftText: "")
                    } label: { Label("Manage agents", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("agent.menu.manage")
                }
                .buttonStyle(.locus())
                .font(.locus(size: 10, weight: .medium))
                .padding(.horizontal, 14).padding(.bottom, 13)
            }
            .frame(width: 320)
            .background(viewColors.surfaceCard)
            .onAppear { searchFocused = true }
            .onChange(of: query) { focusedProfileID = filteredProfiles.first?.id }
            .onMoveCommand { direction in
                if direction == .up || direction == .down { moveFocus(by: direction == .down ? 1 : -1) }
            }
            .onExitCommand { isPresented = false }
        }

        private var searchField: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(viewColors.muted)
                    .accessibilityHidden(true)
                // The field editor swallows arrow keys before a move command
                // reaches the popover, so the field steers the list itself.
                TextField("Search agents", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { moveFocus(by: -1); return .handled }
                    .onKeyPress(.downArrow) { moveFocus(by: 1); return .handled }
                    .onSubmit { chooseFocused() }
                    .accessibilityIdentifier("sidebar.agentPicker.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.locus(.icon))
                        .foregroundStyle(viewColors.muted)
                        .accessibilityLabel("Clear agent search")
                }
            }
            .font(.locus(size: 11))
            .padding(10)
            .background(viewColors.paperDeep.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12).padding(.bottom, 10)
        }

        private var profileList: some View {
            let rows = CGFloat(min(filteredProfiles.count, Self.visibleRows))
            return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(filteredProfiles) { profile in
                            profileRow(profile).id(profile.id)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(height: rows * (Self.rowHeight + Self.rowSpacing) + 4)
                // Initial too: the popover opens focused on the selected
                // agent, which can sit below the visible rows.
                .onChange(of: focusedProfileID, initial: true) {
                    if let focusedProfileID { proxy.scrollTo(focusedProfileID, anchor: .center) }
                }
            }
        }

        private func profileRow(_ profile: AgentProfile) -> some View {
            let selected = selectedProfile?.id == profile.id
            let focused = focusedProfileID == profile.id
            return Button { choose(profile) } label: {
                HStack(spacing: 9) {
                    AgentAvatarView(profileID: profile.id, name: profile.name, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.locus(size: 11, weight: .medium))
                            .foregroundStyle(viewColors.ink)
                            .lineLimit(1)
                        Text(Self.subtitle(profile))
                            .font(.locus(size: 9))
                            .foregroundStyle(viewColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(viewColors.accentAction)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .background(focused ? viewColors.paperDeep.opacity(0.7)
                    : selected ? viewColors.accentAction.opacity(0.07) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel(profile.name)
            .accessibilityValue(Self.subtitle(profile))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("sidebar.agentPicker.profile.\(profile.id.uuidString)")
        }

        private var emptyState: some View {
            VStack(spacing: 7) {
                Text(profiles.isEmpty ? "No agents yet" : "No matching agents")
                    .font(.locus(size: 11, weight: .medium))
                Text(profiles.isEmpty
                    ? "Create an agent with its own instructions, access, and triggers."
                    : "Try an agent name, role, or model.")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(22)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.agentPicker.empty")
        }

        private func choose(_ profile: AgentProfile) {
            isPresented = false
            model.selectSavedAgent(profile)
        }

        private func chooseFocused() {
            let available = filteredProfiles
            guard let profile = available.first(where: { $0.id == focusedProfileID }) ?? available.first
            else { return }
            choose(profile)
        }

        private func moveFocus(by offset: Int) {
            let ids = filteredProfiles.map(\.id)
            guard !ids.isEmpty else { return }
            let next = focusedProfileID.flatMap { ids.firstIndex(of: $0) }
                .map { min(max($0 + offset, 0), ids.count - 1) }
                ?? (offset > 0 ? 0 : ids.count - 1)
            focusedProfileID = ids[next]
        }
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
        .foregroundStyle(viewColors.ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.agentStatus")
        .help("Connection to the local Locus service. Each agent’s status appears beside its name.")
    }

    private var agentStatusText: String {
        switch model.agentRuntimePhase {
        case .starting: "Locus starting"
        case .online: "Locus ready"
        case .recovering: "Reconnecting"
        case .unavailable: "Locus offline"
        }
    }

    private func runtimeColor(_ phase: RuntimePhase) -> Color {
        switch phase {
        case .starting, .recovering: viewColors.warning
        case .online: viewColors.success
        case .unavailable: viewColors.coral
        }
    }

}

private struct SidebarResizeHandle: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspaceLayout: WorkspaceLayoutModel
    @State private var dragStartWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(viewColors.line)
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
                    if dragStartWidth == nil { dragStartWidth = workspaceLayout.sidebarWidth }
                    model.setSidebarWidth((dragStartWidth ?? workspaceLayout.sidebarWidth) + value.translation.width)
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
                    get: { workspaceLayout.sidebarWidth },
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
            .accessibilityValue("\(Int(workspaceLayout.sidebarWidth)) points")
            .accessibilityHint("Drag to resize. Double-click to reset.")
            .accessibilityIdentifier("sidebar.resize")
        }
    }
}

struct TeamProgressPopover: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                            .foregroundStyle(viewColors.coral)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(viewColors.coral.opacity(0.08))
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
        .background(viewColors.panel)
        .accessibilityIdentifier("teamProgress.popover")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(viewColors.signalDeep)
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
                        .foregroundStyle(viewColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dispatcherDetail(activity: activity))
                        .font(.locus(size: 9))
                        .foregroundStyle(viewColors.inkSoft)
                        .lineLimit(4)
                }
                Spacer(minLength: 6)
                if startedAt != nil && runIsActive {
                    Text(duration(elapsed))
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
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
                .foregroundStyle(viewColors.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("teamProgress.dispatcherSlow")
            }
        }
        .padding(10)
        .background(viewColors.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(viewColors.line, lineWidth: 1)
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
                    .foregroundStyle(viewColors.muted)
            }
            if teamRunLive.agentActivities.isEmpty {
                Text(model.orchestrationState == nil
                    ? "No run yet. Send a task with this team selected."
                    : "Jobs appear here after the dispatcher returns a plan.")
                    .font(.locus(size: 9))
                    .foregroundStyle(viewColors.muted)
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
                                .foregroundStyle(viewColors.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(activity.state.title)
                            .font(.locus(size: 8))
                            .foregroundStyle(viewColors.muted)
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
                    Text(profile.specialtyTitle)
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(viewColors.muted)
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
                .foregroundStyle(viewColors.coral)
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
        .foregroundStyle(viewColors.muted)
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
        if model.selectedTeamRouteIssue != nil { return viewColors.coral }
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
            .foregroundStyle(viewColors.muted)
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
        case .completed: viewColors.success
        case .failed, .interrupted, .cancelled, .discarded: viewColors.coral
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            viewColors.warning
        case .queued, .dispatching, .running, .reviewing: viewColors.signalDeep
        case nil: viewColors.muted
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
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                        .fill(viewColors.signalDeep)
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
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                        .foregroundStyle(isDropTarget ? viewColors.signalDeep : viewColors.muted)
                    Text(folder.name)
                        .font(.locus(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(node.chats.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
                }
                .foregroundStyle(viewColors.inkSoft)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(isDropTarget ? viewColors.signal.opacity(0.18) : Color.clear)
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
                        .fill(viewColors.signalDeep)
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
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                    .foregroundStyle(viewColors.muted)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel(expanded ? "Collapse \(group.title)" : "Expand \(group.title)")

            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: group.isOther ? "tray.full" : "folder.fill")
                        .font(.locus(size: SidebarIconMetrics.workspaceSymbolSize, weight: .medium))
                        .foregroundStyle(active ? viewColors.signalDeep : viewColors.muted)
                        .frame(
                            width: SidebarIconMetrics.workspaceIconSize,
                            height: SidebarIconMetrics.workspaceIconSize
                        )
                        .accessibilityIdentifier("workspace.group.icon.\(group.id)")
                    Text(group.title)
                        .font(.locus(size: 10, weight: .medium))
                        .foregroundStyle(viewColors.ink)
                        .lineLimit(1)
                    Text("\(group.chats.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
                        .accessibilityLabel("\(group.chats.count) \(group.chats.count == 1 ? "chat" : "chats")")
                    Spacer(minLength: 3)
                    if !group.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.locus(size: 8))
                            .foregroundStyle(viewColors.warning)
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
                            isHovering || newChatFocused ? viewColors.muted : Color.clear
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
        .background(active ? viewColors.paperDeep.opacity(0.62) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LocusMotion.press, value: isHovering || newChatFocused)
    }
}

private struct SectionLabel: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.locus(size: 8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(viewColors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 5)
    }
}

private struct SessionRow: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

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
                        .foregroundStyle(viewColors.signalDeep)
                        .accessibilityHidden(true)
                }
                if session.isAgentEventChat && !showsAgentIcon {
                    Image(systemName: "bolt.horizontal")
                        .font(.locus(size: 9))
                        .foregroundStyle(viewColors.muted)
                        .help("Automated runs continue in this conversation")
                        .accessibilityLabel("Receives automated work")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.locus(size: 10, weight: isActive ? .medium : .regular))
                        .foregroundStyle(viewColors.ink)
                        .lineLimit(1)
                    if isRunning || teamState != nil {
                        HStack(spacing: 4) {
                            if isRunning {
                                Circle()
                                    .fill(viewColors.signalDeep)
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
                        .foregroundStyle(viewColors.muted)
                        .accessibilityIdentifier("session.\(session.id).activity")
                    }
                }
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(viewColors.muted)
                }
                if session.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(viewColors.muted)
                }
                if isActive {
                    Circle()
                        .fill(viewColors.accentAction)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: showsActivity ? 38 : 30)
            .background(isActive ? viewColors.paperDeep.opacity(0.56) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("Resume \(session.displayTitle)")
        .accessibilityIdentifier("session.\(session.id)")
    }

    private func statusColor(_ state: TeamRunState) -> Color {
        switch state {
        case .completed: viewColors.success
        case .failed: viewColors.coral
        case .interrupted: viewColors.warning
        case .waitingPermission, .waitingComputer: viewColors.warning
        default: viewColors.signalDeep
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

enum AgentSidebarFilter: String, CaseIterable, Identifiable {
    case all, running, attention, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All agents"
        case .running: "Running"
        case .attention: "Needs attention"
        case .paused: "Paused"
        }
    }
    func includes(_ agent: AgentSidebarGroupModel) -> Bool {
        switch self {
        case .all: true
        case .running: agent.runningChatCount > 0
        case .attention: agent.needsAttention
        case .paused: agent.status == .paused
        }
    }
}

/// Observe both definition stores at the hierarchy boundary so a new agent
/// appears immediately, even before its first conversation is available.
private struct AgentSidebarSection: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @ObservedObject var crew: AgentCrewChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var automation: EventAutomationModel
    let snapshot: SessionCatalogSnapshot
    let confirmDelete: (AgentDefinition) -> Void
    let sessionContent: (SessionSummary) -> AnyView
    @State private var filter: AgentSidebarFilter = .all
    @State private var collapsedIDs: Set<String> = []
    @State private var expandedIDs: Set<String> = []
    @State private var showingAllChatIDs: Set<String> = []
    @State private var savedAgentToDelete: AgentSidebarGroupModel?

    private var groups: [AgentSidebarGroupModel] {
        AgentSidebarCatalog.groups(
            definitions: automation.triggers.map(AgentDefinition.trigger)
                + schedule.scheduledTasks.map(AgentDefinition.schedule),
            sessions: snapshot.sessions.filter { crew.boundProfileID(for: $0.id) == nil }, query: snapshot.searchQuery,
            showArchived: snapshot.showArchivedSessions,
            runningSessionIDs: model.runningChatSessionIDs,
            connections: automation.connections, connectionsLoaded: automation.hasLoaded,
            profiles: agentTeams.agentProfiles, recentAgentIDs: model.recentSidebarAgentIDs
        )
    }

    var body: some View {
        let all = groups
        let visible = all.filter(filter.includes)
        LazyVStack(spacing: 3) {
            HStack {
                Text("Group chats")
                    .font(.locus(size: 9, weight: .medium))
                Spacer()
                Text("1")
                    .font(.locus(size: 8, design: .monospaced))
                    .accessibilityLabel("1 group chat")
            }
            .foregroundStyle(viewColors.muted)
            .padding(.horizontal, 9)
            .padding(.bottom, 5)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.groupChats.header")
            CrewChatSidebarEntry(
                selected: model.agentCrewChatPresented || crew.boundProfileID(for: model.currentSessionID) != nil
            )
            .padding(.bottom, 10)
            if !all.isEmpty || filter != .all {
                HStack {
                    Menu {
                        Picker("Show agents", selection: $filter) {
                            ForEach(AgentSidebarFilter.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        Divider()
                        Button("Collapse all") {
                            withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                                collapsedIDs = Set(all.map(\.id))
                                expandedIDs.removeAll()
                            }
                        }
                        Button("Expand all") {
                            withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                                expandedIDs = Set(all.map(\.id))
                                collapsedIDs.removeAll()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title)
                            Image(systemName: "chevron.down").font(.locus(size: 7, weight: .semibold))
                        }
                        .font(.locus(size: 9, weight: .medium))
                        .foregroundStyle(filter == .all ? viewColors.muted : viewColors.accentAction)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.locus())
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Filter agents")
                    .accessibilityIdentifier("sidebar.agentFilter")
                    Spacer()
                    Text("\(visible.count)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(viewColors.muted)
                        .accessibilityLabel("\(visible.count) agents")
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 5)
            }
            if visible.isEmpty {
                emptyState
            } else {
                ForEach(visible) { agent in
                    agentBranch(agent, totalAgents: all.count)
                }
            }
        }
        .onChange(of: snapshot.searchQuery) {
            // A fresh search should reveal matches hidden by a prior filter.
            filter = .all
        }
        .onChange(of: sessionCatalog.sessionReveal?.id, initial: true) {
            guard let request = sessionCatalog.sessionReveal,
                  let group = groups.first(where: { $0.tasks.contains { $0.id == request.sessionID } })
            else { return }
            filter = .all
            collapsedIDs.remove(group.id)
            expandedIDs.insert(group.id)
            showingAllChatIDs.insert(group.id)
        }
        .confirmationDialog(
            savedAgentToDelete?.isUnavailableSavedAgent == true
                ? "Delete unavailable agent and its chats?"
                : "Delete \(savedAgentToDelete?.name ?? "this agent")?",
            isPresented: Binding(
                get: { savedAgentToDelete != nil },
                set: { if !$0 { savedAgentToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let agent = savedAgentToDelete, let profileID = agent.profileID {
                Button(agent.isUnavailableSavedAgent ? "Delete Agent and Chats" : "Delete Agent", role: .destructive) {
                    savedAgentToDelete = nil
                    Task {
                        do {
                            if let profile = agent.profile {
                                try await model.removeSavedAgent(profile)
                            } else {
                                try await model.deleteUnavailableSavedAgent(profileID: profileID)
                            }
                        } catch { model.showToast(error.localizedDescription) }
                    }
                }
                .accessibilityIdentifier("agent.saved.delete.confirm")
            }
            Button("Cancel", role: .cancel) { savedAgentToDelete = nil }
        } message: {
            if savedAgentToDelete?.isUnavailableSavedAgent == true {
                Text("The saved agent is already gone. All of its chats, including archived chats and chats hidden by search, will move to recovery. You can undo this after deleting.")
            } else {
                Text("This removes the saved agent and archives its chats. Completed runs are kept. Turn on Show Archived Sessions to find its history.")
            }
        }
    }

    private func isExpanded(_ agent: AgentSidebarGroupModel, totalAgents: Int) -> Bool {
        if collapsedIDs.contains(agent.id) { return false }
        return !snapshot.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || expandedIDs.contains(agent.id)
            || (agent.profileID != nil && agent.profileID == model.selectedSavedAgentProfile?.id)
            || agent.reference == model.inspectedAgentReference
            || totalAgents <= 3
    }

    private func visibleChats(_ agent: AgentSidebarGroupModel) -> [SessionSummary] {
        if showingAllChatIDs.contains(agent.id) || !snapshot.searchQuery.isEmpty { return agent.tasks }
        let recent = Array(agent.tasks.prefix(4))
        // The open chat must remain visible even when older than the recent four.
        if let current = agent.tasks.first(where: { $0.id == model.currentSessionID }),
           !recent.contains(where: { $0.id == current.id }) {
            return Array(recent.prefix(3)) + [current]
        }
        return recent
    }

    private func agentBranch(_ agent: AgentSidebarGroupModel, totalAgents: Int) -> some View {
        let expanded = isExpanded(agent, totalAgents: totalAgents)
        let chats = visibleChats(agent)
        return VStack(spacing: 1) {
            AgentGroupRow(
                agent: agent, automation: automation, expanded: expanded,
                selected: !model.agentCrewChatPresented && crew.boundProfileID(for: model.currentSessionID) == nil && (agent.profileID != nil ? agent.profileID == model.selectedSavedAgentProfile?.id
                    : agent.reference != nil && model.inspectedAgentReference == agent.reference),
                toggle: {
                    withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                        if expanded {
                            collapsedIDs.insert(agent.id)
                            expandedIDs.remove(agent.id)
                        } else {
                            collapsedIDs.remove(agent.id)
                            expandedIDs.insert(agent.id)
                        }
                    }
                },
                select: {
                    withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                        collapsedIDs.remove(agent.id)
                        expandedIDs.insert(agent.id)
                    }
                    if let profile = agent.profile { model.selectSavedAgent(profile) }
                    else if let reference = agent.reference { model.selectAgent(reference, fromSidebarRow: true) }
                    else { model.showToast("This agent is unavailable. Its saved chats are still available below.") }
                },
                confirmDelete: confirmDelete,
                confirmDeleteSavedAgent: { savedAgentToDelete = $0 }
            )
            if expanded {
                VStack(spacing: 1) {
                    ForEach(chats) { session in sessionContent(session) }
                    if agent.tasks.count > 4 && snapshot.searchQuery.isEmpty {
                        Button {
                            withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                                if showingAllChatIDs.contains(agent.id) { showingAllChatIDs.remove(agent.id) }
                                else { showingAllChatIDs.insert(agent.id) }
                            }
                        } label: {
                            Text(showingAllChatIDs.contains(agent.id)
                                ? "Show recent chats" : "Show all \(agent.tasks.count) chats")
                                .font(.locus(size: 9, weight: .medium))
                                .foregroundStyle(viewColors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 26)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("agent.\(agent.accessibilityID).showChats")
                    }
                    if agent.tasks.isEmpty {
                        Button {
                            if let profile = agent.profile { model.newSavedAgentChat(profile) }
                            else if let reference = agent.reference { model.newAgentChat(reference: reference) }
                        } label: {
                            Label("Start a conversation", systemImage: "plus.bubble")
                                .font(.locus(size: 9))
                                .foregroundStyle(viewColors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                        }
                        .buttonStyle(.locus())
                        .disabled((agent.reference == nil && agent.profile == nil) || model.chatNavigationDisabled)
                        .accessibilityIdentifier("agent.\(agent.accessibilityID).firstChat")
                    }
                }
                .padding(.leading, 32)
                .overlay(alignment: .leading) {
                    Rectangle().fill(viewColors.line.opacity(0.7)).frame(width: 1)
                        .padding(.leading, 22).padding(.vertical, 3)
                }
                .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
        }
    }

    private var emptyState: some View {
        let isLoading = automation.isRefreshing || schedule.isRefreshingSchedules
        let isFiltered = filter != .all || !snapshot.searchQuery.isEmpty
        let unavailable = !automation.hasLoaded || !schedule.hasLoaded
        return VStack(spacing: 10) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Loading agents…").font(.locus(size: 10, weight: .medium))
            } else {
                Image(locusSymbol: LocusSymbol.robot)
                    .font(.locus(size: 22))
                    .foregroundStyle(viewColors.accentAction)
                    .padding(.bottom, 3)
                Text(isFiltered ? "No matching agents" : unavailable ? "Agents unavailable" : "Your own agents")
                    .font(.locus(size: 11, weight: .semibold))
                Text(isFiltered
                    ? "Try another name or show all agents."
                    : unavailable
                        ? "Reconnect to load your agents and their activity."
                        : "Give an agent a name, model, and instructions. Its chats and automatic work stay together.")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isFiltered {
                    Button("Clear filters") {
                        filter = .all
                        model.sessionCatalog.setSearchQuery("")
                    }
                    .buttonStyle(.locus())
                } else if unavailable {
                    Button("Try again") {
                        Task {
                            await automation.refresh(announceFailure: true)
                            await schedule.refreshScheduledTasks(announceFailure: true)
                        }
                    }
                    .buttonStyle(.locus())
                } else {
                    Button { model.presentNewAgent() } label: {
                        Label("Create an agent", systemImage: "plus")
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(viewColors.accentAction)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(viewColors.accentAction.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.locus())
                    .accessibilityIdentifier("sidebar.empty.newAgent")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 15)
        .padding(.vertical, 26)
    }
}

/// One agent's group header in the sidebar.
///
/// It observes the trigger and schedule stores directly rather than reading
/// them back through AppModel: pausing or deleting an agent from this row
/// publishes only on those stores, so a row that watched AppModel alone kept
/// drawing the state the agent had before the click.
private struct AgentGroupRow: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var schedule: ScheduleModel
    @ObservedObject var automation: EventAutomationModel
    let agent: AgentSidebarGroupModel
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void
    let select: () -> Void
    let confirmDelete: (AgentDefinition) -> Void
    let confirmDeleteSavedAgent: (AgentSidebarGroupModel) -> Void

    init(
        agent: AgentSidebarGroupModel,
        automation: EventAutomationModel,
        expanded: Bool,
        selected: Bool,
        toggle: @escaping () -> Void,
        select: @escaping () -> Void,
        confirmDelete: @escaping (AgentDefinition) -> Void,
        confirmDeleteSavedAgent: @escaping (AgentSidebarGroupModel) -> Void
    ) {
        self.agent = agent
        self.automation = automation
        self.expanded = expanded
        self.selected = selected
        self.toggle = toggle
        self.select = select
        self.confirmDelete = confirmDelete
        self.confirmDeleteSavedAgent = confirmDeleteSavedAgent
    }

    private var definition: AgentDefinition? {
        agent.reference.flatMap(model.inspectorAgentDefinition)
    }

    var body: some View {
        let record = definition
        let status = agent.status
        let words = record?.vocabulary ?? .events
        let showsWarning = agent.runningChatCount == 0 && agent.needsAttention
        return HStack(spacing: 3) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .font(.locus(size: 8, weight: .bold))
                    .foregroundStyle(viewColors.muted)
                    .frame(width: 20, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .help(expanded ? "Collapse \(agent.name)" : "Expand \(agent.name)")
            .accessibilityLabel(expanded ? "Collapse \(agent.name)" : "Expand \(agent.name)")
            .accessibilityIdentifier("agent.\(agent.accessibilityID).disclosure")

            Button(action: select) {
                HStack(spacing: 8) {
                    if let profileID = agent.profileID {
                        AgentAvatarView(profileID: profileID, name: agent.name, size: 28)
                    } else {
                    Image(locusSymbol: LocusSymbol.robot)
                        .font(.locus(size: 12, weight: .semibold))
                        .foregroundStyle(showsWarning ? viewColors.warning : viewColors.accentAction)
                        .frame(width: 25, height: 25)
                        .background(viewColors.accentAction.opacity(selected ? 0.12 : 0.06),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name)
                            .font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(viewColors.ink)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if agent.runningChatCount > 0 {
                                Circle().fill(viewColors.accentAction).frame(width: 4, height: 4)
                            } else if agent.sourceNeedsAttention || status != .active {
                                Image(systemName: agent.sourceNeedsAttention ? "exclamationmark.circle.fill" : Self.statusSymbol(status))
                                    .font(.locus(size: 7))
                            }
                            Text(agent.runningChatCount > 0 || agent.sourceNeedsAttention || status != .active
                                ? agent.statusTitle : agent.profile?.specialtyTitle ?? record?.kindTitle ?? "Saved chats")
                            Text("·")
                            Text("\(agent.totalChatCount) \(agent.totalChatCount == 1 ? "chat" : "chats")")
                        }
                        .font(.locus(size: 8))
                        .foregroundStyle(showsWarning ? viewColors.warning : viewColors.muted)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .help("View \(agent.name)’s instructions, triggers, access, and activity")
            .accessibilityLabel("\(agent.name) agent")
            .accessibilityValue(
                "\(agent.statusTitle), \(agent.totalChatCount) chats, "
                    + (selected ? "selected for new chats" : "not selected")
            )
            .accessibilityIdentifier("agent.\(agent.accessibilityID)")

            Menu { agentActions } label: {
                Image(systemName: "ellipsis")
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(viewColors.muted)
                    .frame(width: 22, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.locus(.icon))
            .menuIndicator(.hidden)
            .help("Actions for \(agent.name)")
            .accessibilityLabel("Actions for \(agent.name)")
            .accessibilityIdentifier("agent.\(agent.accessibilityID).actions")
        }
        .padding(.trailing, 4)
        .background(selected ? viewColors.accentAction.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu { agentActions }
        .help(agent.isUnavailableSavedAgent
            ? "This saved agent is unavailable. Review its chats below, or delete the leftover entry from its menu."
            : agent.profileID != nil
            ? (agent.needsAttention ? "Open Manage Agent to review its automatic work." : "Open this agent’s chats and manage its instructions and automatic work.")
            : agent.sourceNeedsAttention ? "This Agent’s source connection needs attention. Open its settings to review the connection." : status.detail(for: words))
    }

    @ViewBuilder
    private var agentActions: some View {
        if !agent.isUnavailableSavedAgent {
            Button("New Chat with \(agent.name)") {
                if let profile = agent.profile { model.newSavedAgentChat(profile) }
                else if let reference = agent.reference { model.newAgentChat(reference: reference) }
            }
            .disabled((agent.reference == nil && agent.profile == nil) || model.chatNavigationDisabled)
            .accessibilityIdentifier("agent.\(agent.accessibilityID).newChat")
        }
        if let profile = agent.profile {
            Button("Manage Agent…") { model.manageSavedAgent(profile) }
                .accessibilityIdentifier("agent.\(agent.accessibilityID).manage")
            Button("Edit Agent…") { model.presentSavedAgentEditor(profile) }
                .accessibilityIdentifier("agent.\(agent.accessibilityID).edit")
        }
        if let profileID = agent.profileID {
            if agent.profile != nil { Divider() }
            Button(agent.isUnavailableSavedAgent ? "Delete Agent and Chats…" : "Delete Agent…", role: .destructive) {
                confirmDeleteSavedAgent(agent)
            }
            .disabled(model.isBusy || model.hasPendingPermission || model.pendingSessionReset
                || agent.runningChatCount > 0 || model.removingSavedAgentIDs.contains(profileID))
            .accessibilityIdentifier("agent.\(agent.accessibilityID).delete")
        }
        if let record = definition {
            if record.isSchedule {
                Button("Run Now") { model.runAgentNow(record) }
                    .accessibilityIdentifier("agent.\(agent.accessibilityID).runNow")
            }
            Button("Edit Agent…") { model.editAgent(record) }
                .accessibilityIdentifier("agent.\(agent.accessibilityID).edit")
            if record.lastError?.nilIfEmpty != nil {
                Button(model.isClearingAgentWarning(record) ? "Clearing Warning…" : "Clear Warning") {
                    model.clearAgentWarning(record)
                }
                .disabled(model.isClearingAgentWarning(record))
                .accessibilityIdentifier("agent.\(agent.accessibilityID).clearWarning")
            }
            Button(record.enabled ? "Pause Agent" : "Resume Agent") {
                model.setAgentEnabled(record, enabled: !record.enabled)
            }
            .disabled(model.isChangingAgentEnabled(record))
            .accessibilityIdentifier("agent.\(agent.accessibilityID).toggle")
            Divider()
            Button("Delete Agent…", role: .destructive) { confirmDelete(record) }
                .accessibilityIdentifier("agent.\(agent.accessibilityID).delete")
        }
    }

    private static func statusSymbol(_ status: AgentOverview.Status) -> String {
        switch status {
        case .active: "circle"
        case .paused: "pause.circle.fill"
        case .stopped, .missingTrigger: "exclamationmark.triangle.fill"
        case .failing: "exclamationmark.circle.fill"
        case .fired: "checkmark.circle.fill"
        }
    }
}
