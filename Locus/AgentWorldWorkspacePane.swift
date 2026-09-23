import SwiftUI

/// A small, native conversation over the map. It shares the normal transcript
/// and composer, including saved drafts and approvals, without mounting tools.
struct AgentWorldMapChat: View {
    @ObservedObject var world: AgentWorldModel
    @ObservedObject var model: AppModel
    private var palette: AgentWorldPalette { .init(ocean: world.theme == "grand-line") }
    private var residents: [AgentWorldResident] { world.residents }
    private var resident: AgentWorldResident? { residents.first { $0.id == world.selection } }
    private var conversations: [SessionSummary] { world.selection.map(world.residentConversations(for:)) ?? [] }
    private var isSelectedConversationActive: Bool {
        guard let sessionID = world.selectedSessionID, sessionID == model.currentSessionID,
              let profile = world.selectedProfile else { return false }
        return model.sessions.first(where: { $0.id == sessionID })?.belongsToWorkspace(world.workspace) == true
            && (model.savedAgentProfileID(for: sessionID) ?? world.boundProfileID(for: sessionID)) == profile.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            palette.line.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.warning.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .onChange(of: model.currentSessionID) { _, _ in world.adoptForegroundConversation() }
        .accessibilityIdentifier("agentWorld.mapChat")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(residents, id: \.id) { item in
                    Button { world.chooseResident(item.id) } label: {
                        if item.id == world.selection { Label(item.name, systemImage: "checkmark") }
                        else { Text(item.name) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let profile = world.selectedProfile {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 26)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(world.selectedProfile?.name ?? "Agent").font(.locus(size: 12, weight: .semibold)).lineLimit(1)
                        if let resident {
                            HStack(spacing: 4) {
                                Circle().fill(AgentWorldChrome.statusColor(resident.status)).frame(width: 5, height: 5)
                                Text(AgentWorldChrome.statusLabel(resident.status, ocean: world.theme == "grand-line"))
                                    .font(.locus(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .help("Switch agent and follow their ship")
            .accessibilityLabel("Chat with \(world.selectedProfile?.name ?? "agent"). Switch agent")
            .accessibilityIdentifier("agentWorld.mapChat.agentPicker")
            iconButton("chevron.left", "Previous agent", "previous") { switchAgent(by: -1) }
                .disabled(residents.count < 2)
            iconButton("chevron.right", "Next agent", "next") { switchAgent(by: 1) }
                .disabled(residents.count < 2)
            Menu {
                Button("New chat", action: world.newConversation)
                    .disabled(!world.canStartConversation(for: world.selection ?? ""))
                if !conversations.isEmpty {
                    Menu("Recent chats") {
                        ForEach(conversations, id: \.id) { chat in
                            Button { world.openResidentConversation(chat) } label: {
                                if chat.id == world.selectedSessionID { Label(chat.name.nilIfEmpty ?? "Untitled chat", systemImage: "checkmark") }
                                else { Text(chat.name.nilIfEmpty ?? "Untitled chat") }
                            }
                        }
                    }
                }
                Button("Agent overview") { world.openAgentProfile() }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 28) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Chat options").accessibilityIdentifier("agentWorld.mapChat.options")
            iconButton("arrow.up.left.and.arrow.down.right", "Open full workspace", "expand") { world.quartersPresented = true }
            iconButton("xmark", "Close chat", "close", action: world.clearWorldSelection)
        }
        .padding(.horizontal, 10).frame(height: 50)
        .background(palette.panel)
    }

    private func iconButton(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.locus(size: 11, weight: .medium)).frame(width: 24, height: 28) }
            .buttonStyle(.locus(.icon)).help(label).accessibilityLabel(label)
            .accessibilityIdentifier("agentWorld.mapChat.\(id)")
    }

    private func switchAgent(by offset: Int) {
        guard !residents.isEmpty, let index = residents.firstIndex(where: { $0.id == world.selection }) else { return }
        world.chooseResident(residents[(index + offset + residents.count) % residents.count].id)
    }

    @ViewBuilder private var content: some View {
        if !world.canInteract {
            Text("Agent conversations are currently unavailable.").font(.locus(size: 12)).padding(20)
        } else if world.preparingConversation || world.activatingConversation {
            ProgressView("Opening chat…").controlSize(.small)
        } else if isSelectedConversationActive {
            GeometryReader { geometry in
                WorkspaceView(sidebarVisible: true, showSidebar: {}, presentsAgentOverview: false,
                              openAgentOverview: { world.openAgentProfile() }, compactHeader: true, showsHeader: false)
                    .environment(\.locusWorkspaceGeometry, WorkspaceGeometrySnapshot(
                        windowSize: geometry.size, workspaceWidth: geometry.size.width,
                        workspaceHeight: geometry.size.height, composerWidth: geometry.size.width))
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.locus(size: 24)).foregroundStyle(palette.warning)
                Text(world.error ?? "Chat with \(world.selectedProfile?.name ?? "this agent") while keeping an eye on your world.")
                    .font(.locus(size: 12)).multilineTextAlignment(.center).foregroundStyle(palette.muted)
                if world.selectedSessionID == nil {
                    Button("Start chat", action: world.newConversation)
                        .buttonStyle(AgentWorldChromeButtonStyle(selected: true))
                        .disabled(!world.canStartConversation(for: world.selection ?? ""))
                        .accessibilityIdentifier("agentWorld.mapChat.start")
                } else {
                    Button("Resume chat") { world.showSelectedChat() }
                        .buttonStyle(AgentWorldChromeButtonStyle(selected: true))
                        .accessibilityIdentifier("agentWorld.mapChat.resume")
                }
            }.padding(24)
        }
    }
}

/// The map chooses a resident; the existing Locus workspace owns every chat,
/// approval and task action. The pinned identity guard prevents a different
/// foreground chat from silently becoming this resident's conversation.
struct AgentWorldWorkspacePane: View {
    @ObservedObject var world: AgentWorldModel
    @ObservedObject var model: AppModel
    let title: String
    var onRequestChatSpace: () -> Void = {}
    @State private var showsTools = true
    @State private var toolsWidth: CGFloat?
    @State private var resizeStart: CGFloat?
    @State private var activityContext: AgentInspectorContext?
    private var ocean: Bool { world.theme == "grand-line" }
    private var palette: AgentWorldPalette { .init(ocean: ocean, deck: world.usesWoodQuarters, island: world.activeQuartersIsland) }
    private var resident: AgentWorldResident? { world.residents.first { $0.id == world.selection } }
    private var placement: AgentWorldResidentPlacement? { world.selection.flatMap { world.residentPlacements[$0] } }
    private var residentConversations: [SessionSummary] {
        world.selection.map(world.residentConversations(for:)) ?? []
    }
    private var selectedConversationTitle: String {
        guard let id = world.selectedSessionID else { return "Chats" }
        return residentConversations.first(where: { $0.id == id })?.name.nilIfEmpty ?? "Chat"
    }

    private enum Pane: String, CaseIterable { case details = "Overview", chat = "Chat", crew = "Crew Chat" }
    private var selectedPane: Binding<Pane> {
        Binding(get: { world.sharedChatPresented ? .crew : world.profilePresented ? .details : .chat }, set: { pane in
            switch pane {
            case .crew: world.openSharedChat()
            case .details: world.openAgentProfile()
            case .chat:
                if world.profilePresented || world.sharedChatPresented { world.showSelectedChat() }
                else if !isSelectedConversationActive { world.activateSelectedConversation() }
            }
        })
    }
    private var isSelectedConversationActive: Bool {
        world.selectedSessionID != nil && world.selectedSessionID == model.currentSessionID
            && model.sessions.first(where: { $0.id == model.currentSessionID })?.belongsToWorkspace(world.workspace) == true
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width)
            VStack(spacing: 0) {
                header
                paneContent(width: contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.paper)

            }
            .onChange(of: proxy.size.width) { _, width in
                if width < 700 { showsTools = false }
            }
            .onChange(of: showsTools) { _, shown in
                if shown && proxy.size.width < 700 { onRequestChatSpace() }
            }
            .environment(\.locusWorkspaceGeometry, WorkspaceGeometrySnapshot(
                windowSize: proxy.size, workspaceWidth: contentWidth,
                workspaceHeight: max(0, proxy.size.height - 48), composerWidth: contentWidth
            ))
        }
        .background(palette.panel)
        .foregroundStyle(palette.ink)
        .onChange(of: world.selection) { _, _ in activityContext = nil }
        .onChange(of: model.currentSessionID) { _, _ in world.adoptForegroundConversation() }
        .onChange(of: world.workspaceToolsRequest) { _, _ in showsTools = true }
        .onChange(of: model.inspectorCollapsed) { _, collapsed in
            if isSelectedConversationActive && !world.profilePresented { showsTools = !collapsed }
        }
        .onChange(of: model.inspectorTab) { _, _ in
            if model.agentWorldOwnsPresentations, isSelectedConversationActive,
               !world.activatingConversation, !world.sharedChatPresented, !world.profilePresented, !model.inspectorCollapsed {
                showsTools = true
            }
        }
        .accessibilityIdentifier("agentWorld.workspace")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let profile = world.selectedProfile, !world.sharedChatPresented {
                AgentAvatarView(profileID: profile.id, name: profile.name, size: 28)
            } else { ZStack {
                Circle().stroke(palette.warning.opacity(0.2), lineWidth: 1)
                Circle().stroke(palette.warning.opacity(0.3), lineWidth: 1).padding(5)
                Image(systemName: ocean ? "safari" : "square.stack.3d.up")
                    .font(.locus(size: 24, weight: .ultraLight))
            }
            .foregroundStyle(ocean ? palette.warning : palette.signal)
            .frame(width: 34, height: 34).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(world.sharedChatPresented ? "Crew Chat" : world.selectedProfile?.name ?? "Agent workspace")
                    .font(.locus(size: 13, weight: .semibold)).lineLimit(1)
                if !world.sharedChatPresented, let resident {
                    HStack(spacing: 4) {
                        Circle().fill(AgentWorldChrome.statusColor(resident.status)).frame(width: 5, height: 5)
                        Text(AgentWorldChrome.statusLabel(resident.status, ocean: ocean))
                            .font(.locus(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
            }.frame(minWidth: 60, alignment: .leading)
            if !world.sharedChatPresented, world.selectedProfile != nil, !residentConversations.isEmpty {
                Menu {
                    ForEach(residentConversations, id: \.id) { conversation in
                        Button {
                            world.openResidentConversation(conversation)
                        } label: {
                            if conversation.id == world.selectedSessionID {
                                Label(conversation.name.nilIfEmpty ?? "Untitled chat", systemImage: "checkmark")
                            } else { Text(conversation.name.nilIfEmpty ?? "Untitled chat") }
                        }
                    }
                } label: {
                    Label(selectedConversationTitle, systemImage: "chevron.down")
                        .font(.locus(size: 11, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Switch between this agent’s chats")
                .accessibilityLabel("Chat for \(world.selectedProfile?.name ?? "agent"): \(selectedConversationTitle)")
                .accessibilityIdentifier("agentWorld.workspace.chatPicker")
            }
            Spacer(minLength: 8)
            workspaceTabs
            if let profile = world.selectedProfile, !world.sharedChatPresented {
                Button(action: world.newConversation) {
                    Image(systemName: "plus.bubble").frame(width: 28, height: 28)
                }.buttonStyle(.locus(.icon))
                    .disabled(!world.canStartConversation(for: profile.id.uuidString))
                    .help("New chat with \(profile.name)").accessibilityLabel("New chat with \(profile.name)")
                    .accessibilityIdentifier("agentWorld.workspace.header.newChat")
                Menu {
                    Button("New chat", action: world.newConversation).disabled(!world.canStartConversation(for: profile.id.uuidString))
                    if ocean {
                        Menu("Ship style") { AgentWorldShipStyleOptions(world: world, agentID: profile.id.uuidString) }
                            .disabled(world.activeScreen?.screen.capabilities.contains("world.preferences") != true)
                    }
                    Divider()
                    Button("Edit agent…") { model.presentSavedAgentEditor(profile) }
                    Button("Manage agent…") { model.manageSavedAgent(profile, workspace: world.workspace) }
                } label: {
                    Image(systemName: "ellipsis").font(.locus(size: 14, weight: .semibold))
                        .frame(width: 29, height: 28)
                        .background(palette.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(!world.canInteract)
                .accessibilityLabel("Agent actions")
                .accessibilityIdentifier("agentWorld.workspace.actions")
            }
            Button(action: world.dismissConversation) { Image(systemName: "xmark").font(.locus(size: 11)).frame(width: 29, height: 28) }
                .buttonStyle(.locus(.icon))
                .background(palette.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .help(world.quartersPresented ? "Clear agent selection" : "Return to the world").accessibilityLabel("Close agent workspace")
                .accessibilityIdentifier("agentWorld.closeConversation")
        }.padding(.horizontal, 12).frame(height: 48)
            .overlay(alignment: .bottom) { palette.line.frame(height: 1) }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 4) {
            ForEach(world.sharedChatPresented ? [Pane.crew] : [.details, .chat], id: \.self) { pane in
                Button { selectedPane.wrappedValue = pane } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tabIcon(pane)).font(.locus(size: 11))
                        Text(tabTitle(pane)).font(.locus(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(selectedPane.wrappedValue == pane ? palette.warning : palette.muted)
                    .background(selectedPane.wrappedValue == pane ? palette.white : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedPane.wrappedValue == pane ? palette.warning.opacity(0.26) : .clear, lineWidth: 1))
                }
                .buttonStyle(.locus(.quiet))
                .accessibilityLabel(tabTitle(pane))
                .accessibilityAddTraits(selectedPane.wrappedValue == pane ? [.isSelected] : [])
                .help(pane == .details ? "Agent settings, chats, automations, and recent results" : pane.rawValue)
                .accessibilityIdentifier("agentWorld.workspace.tab.\(pane)")
            }
            if !world.sharedChatPresented && !world.profilePresented {
                Button {
                    showsTools.toggle()
                    if showsTools { model.selectInspectorTab(model.inspectorTab == .agent ? .preview : model.inspectorTab) }
                } label: {
                    Label(showsTools ? "Hide tools" : "Show tools", systemImage: "sidebar.right")
                        .font(.locus(size: 11, weight: .semibold))
                }.buttonStyle(AgentWorldChromeButtonStyle(selected: showsTools))
                    .help("Keep browser, files, calendar, and task board beside your chat")
                    .accessibilityIdentifier("agentWorld.workspace.toggleTools")
            }
        }

        .accessibilityIdentifier("agentWorld.workspace.tabs")
    }

    private func tabTitle(_ pane: Pane) -> String {
        switch pane {
        case .chat: "Chat"
        case .details: "Overview"
        case .crew: "Crew Chat"
        }
    }

    private func tabIcon(_ pane: Pane) -> String {
        switch pane {
        case .chat: "text.bubble"
        case .details: "person.text.rectangle"
        case .crew: "person.3"
        }
    }

    @ViewBuilder
    private func paneContent(width: CGFloat) -> some View {
        if world.sharedChatPresented {
            AgentWorldCrewPane(world: world, crew: model.agentCrewChat)
        } else if !world.canInteract {
            ContentUnavailableView("Interaction unavailable", systemImage: "lock", description: Text("This world's access to agent conversations is no longer available."))
        } else if world.profilePresented, let profile = world.selectedProfile {
            SavedAgentInspectorView(profile: profile, workspace: world.workspace,
                                    newChat: { world.newConversation(for: profile.id.uuidString) },
                                    openChat: world.openResidentConversation,
                                    newChatDisabled: !world.canStartConversation(for: profile.id.uuidString),
                                    inspectActivity: { context in
                                        activityContext = context
                                        model.agentInspector.show(context)
                                        model.selectInspectorTab(.agent)
                                        world.showSelectedTools()
                                        showsTools = true
                                    })
                .id(profile.id)
                .accessibilityIdentifier("agentWorld.workspace.profile")
        } else if let activityContext, activityContext == model.agentInspector.context, !isSelectedConversationActive {
            InspectorAgentTab()
        } else if world.activatingConversation || world.preparingConversation {
            VStack(spacing: 12) { ProgressView(); Text("Opening your conversation…").foregroundStyle(palette.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSelectedConversationActive {
            let inspectorWidth = min(max(304, toolsWidth ?? width * 0.35), max(304, width - 383))
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    WorkspaceView(sidebarVisible: true, showSidebar: {}, presentsAgentOverview: false,
                                  openAgentOverview: { world.openAgentProfile() }, compactHeader: true)
                        .environment(\.locusWorkspaceGeometry, WorkspaceGeometrySnapshot(
                            windowSize: geometry.size, workspaceWidth: geometry.size.width,
                            workspaceHeight: geometry.size.height, composerWidth: geometry.size.width))
                        .accessibilityIdentifier("agentWorld.workspace.chat")
                }.frame(minWidth: 320, maxWidth: .infinity)
                    .onAppear {
                        if showsTools && model.inspectorTab == .agent { model.selectInspectorTab(.preview) }
                    }
                if showsTools && width >= 700 {
                    Rectangle().fill(palette.line.opacity(0.65)).frame(width: 3)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if resizeStart == nil { resizeStart = inspectorWidth }
                            toolsWidth = min(max(304, (resizeStart ?? inspectorWidth) - value.translation.width), max(304, width - 383))
                        }.onEnded { _ in resizeStart = nil })
                        .accessibilityLabel("Resize chat and tools")
                        .accessibilityAdjustableAction { direction in
                            toolsWidth = min(max(304, inspectorWidth + (direction == .increment ? 40 : -40)), max(304, width - 383))
                        }
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            InspectorView(resizeWidth: max(260, geometry.size.width - InspectorRail.width), showsResizeHandle: false)
                            InspectorRail(suppressDuplicateAgentOverview: false)
                        }
                    }.frame(width: inspectorWidth)
                        .accessibilityIdentifier("agentWorld.workspace.inspector")
                }
            }
        } else {
            ContentUnavailableView {
                Label(world.selectedProfile == nil ? "Meet an agent" : world.selectedSessionID == nil ? "Start a chat" : "Resume this conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(world.error ?? (world.selectedProfile == nil
                    ? "Select an agent to open their full Locus workspace. Crew Chat is available alongside every agent."
                    : "Another conversation is active in Locus. Resume \(world.selectedProfile?.name ?? "this agent") here to use its chat and controls."))
            } actions: {
                if world.selectedProfile != nil {
                    Button("Start chat", action: world.newConversation)
                        .buttonStyle(.borderedProminent)
                        .disabled(!world.canStartConversation(for: world.selection ?? ""))
                        .accessibilityIdentifier("agentWorld.workspace.newChat")
                    if let profile = world.selectedProfile {
                        Button("Set up automation") { model.manageSavedAgent(profile, workspace: world.workspace) }
                            .accessibilityIdentifier("agentWorld.workspace.setupAutomation")
                    }
                    if world.selectedSessionID != nil {
                        Button("Try again") { world.showSelectedChat() }
                            .accessibilityIdentifier("agentWorld.workspace.resume")
                    }
                }
            }
        }
    }
}

private struct AgentWorldCrewPane: View {
    @ObservedObject var world: AgentWorldModel
    @ObservedObject var crew: AgentCrewChatModel

    var body: some View {
        if crew.workspace == world.workspace {
            AgentCrewChatView(model: crew, allowsInteraction: world.canInteract)
        } else {
            ContentUnavailableView {
                Label("Return to this crew", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Crew Chat is showing another project in the main window. Reopen \(world.projectName)’s shared conversation here.")
            } actions: {
                Button("Open this crew", action: world.openSharedChat).disabled(!world.canInteract)
            }
        }
    }
}
