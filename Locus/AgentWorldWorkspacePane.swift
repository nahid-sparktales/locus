import SwiftUI

/// The map chooses a resident; the existing Locus workspace owns every chat,
/// approval and task action. The pinned identity guard prevents a different
/// foreground chat from silently becoming this resident's conversation.
struct AgentWorldWorkspacePane: View {
    @ObservedObject var world: AgentWorldModel
    @ObservedObject var model: AppModel
    let title: String
    @State private var showsTools = false
    @State private var activityContext: AgentInspectorContext?
    private var ocean: Bool { world.theme == "grand-line" }
    private var palette: AgentWorldPalette { .init(ocean: ocean) }
    private var resident: AgentWorldResident? { world.residents.first { $0.id == world.selection } }
    private var placement: AgentWorldResidentPlacement? { world.selection.flatMap { world.residentPlacements[$0] } }

    private enum Pane: String, CaseIterable { case chat = "Chat", details = "Agent details", tools = "Tools", crew = "Crew Chat" }
    private var selectedPane: Binding<Pane> {
        Binding(get: { world.sharedChatPresented ? .crew : world.profilePresented ? .details : showsTools ? .tools : .chat }, set: { pane in
            showsTools = pane == .tools
            switch pane {
            case .crew: world.openSharedChat()
            case .details: world.openAgentProfile()
            case .chat, .tools:
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
            let contentWidth = max(0, proxy.size.width - 24)
            VStack(spacing: 0) {
                header
                workspaceTabs
                paneContent(width: contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.line, lineWidth: 1))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .environment(\.locusWorkspaceGeometry, WorkspaceGeometrySnapshot(
                windowSize: proxy.size, workspaceWidth: contentWidth,
                workspaceHeight: max(0, proxy.size.height - 155), composerWidth: contentWidth
            ))
        }
        .background(palette.panel)
        .foregroundStyle(palette.ink)
        .onChange(of: world.selection) { _, _ in showsTools = false }
        .onChange(of: model.currentSessionID) { _, _ in world.adoptForegroundConversation() }
        .onChange(of: model.inspectorTab) { _, _ in
            if model.agentWorldOwnsPresentations, isSelectedConversationActive,
               !world.activatingConversation, !world.sharedChatPresented, !world.profilePresented, !model.inspectorCollapsed {
                showsTools = true
            }
        }
        .accessibilityIdentifier("agentWorld.workspace")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().stroke(palette.warning.opacity(0.2), lineWidth: 1)
                Circle().stroke(palette.warning.opacity(0.3), lineWidth: 1).padding(5)
                Image(systemName: ocean ? "safari" : "square.stack.3d.up")
                    .font(.locus(size: 24, weight: .ultraLight))
            }
            .foregroundStyle(ocean ? palette.warning : palette.signal)
            .frame(width: 47, height: 47).padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.locus(size: 8, weight: .semibold)).tracking(2.1)
                    .foregroundStyle(palette.warning)
                Text(world.sharedChatPresented ? "The crew’s table" : world.selectedProfile?.name ?? "Welcome aboard")
                    .font(ocean ? .locus(size: 26, weight: .medium, design: .serif) : .locus(size: 22, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !world.sharedChatPresented, let resident {
                        Circle().fill(AgentWorldChrome.statusColor(resident.status)).frame(width: 5, height: 5)
                    }
                    Text(world.sharedChatPresented ? "Shared plans. Bigger adventures." : placement.map { "\($0.ship) · \($0.home)" }
                         ?? world.conversationContext ?? resident?.role.capitalized ?? "Choose a resident to chart your next course")
                        .font(.locus(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let profile = world.selectedProfile {
                Menu {
                    Button("New chat", action: world.newConversation).disabled(!world.canStartConversation(for: profile.id.uuidString))
                    if ocean {
                        Menu("Ship style") { AgentWorldShipStyleOptions(world: world, agentID: profile.id.uuidString) }
                            .disabled(world.activeScreen?.screen.capabilities.contains("world.preferences") != true)
                    }
                    Divider()
                    Button("Edit agent…") { model.presentSavedAgentEditor(profile) }
                    Button("Manage agent…") { model.manageSavedAgent(profile) }
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
                .help("Return to the world").accessibilityLabel(ocean ? "Close Captain’s Quarters" : "Close agent workspace")
                .accessibilityIdentifier("agentWorld.closeConversation")
        }.padding(.horizontal, 21).padding(.top, 21).padding(.bottom, 18)
    }

    private var workspaceTabs: some View {
        HStack(spacing: 4) {
            ForEach(Pane.allCases, id: \.self) { pane in
                Button { selectedPane.wrappedValue = pane } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tabIcon(pane)).font(.locus(size: 11))
                        Text(tabTitle(pane)).font(.locus(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(selectedPane.wrappedValue == pane ? palette.warning : palette.muted)
                    .background(selectedPane.wrappedValue == pane ? palette.white : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedPane.wrappedValue == pane ? palette.warning.opacity(0.26) : .clear, lineWidth: 1))
                }
                .buttonStyle(.locus(.quiet))
                .accessibilityLabel(tabTitle(pane))
                .accessibilityAddTraits(selectedPane.wrappedValue == pane ? [.isSelected] : [])
                .help(pane == .details && ocean ? "Vivre card · this resident’s profile and chats" : pane.rawValue)
            }
        }
        .padding(4).background(palette.paper, in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .accessibilityIdentifier("agentWorld.workspace.tabs")
    }

    private func tabTitle(_ pane: Pane) -> String {
        switch pane {
        case .chat: ocean ? "Captain’s log" : "Chat"
        case .details: ocean ? "Vivre card" : "Agent details"
        case .tools: "Tools"
        case .crew: "Crew Chat"
        }
    }

    private func tabIcon(_ pane: Pane) -> String {
        switch pane {
        case .chat: "text.bubble"
        case .details: "person.text.rectangle"
        case .tools: "sidebar.right"
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
        } else if showsTools {
            if isSelectedConversationActive {
                HStack(spacing: 0) {
                    InspectorView(resizeWidth: max(300, width - InspectorRail.width))
                    InspectorRail(suppressDuplicateAgentOverview: false)
                }
                .accessibilityIdentifier("agentWorld.workspace.inspector")
            } else if let activityContext, activityContext == model.agentInspector.context {
                // Read-only activity needs no active chat. General workspace
                // tools must remain tied to an activated resident conversation.
                InspectorAgentTab()
            } else {
                ContentUnavailableView {
                    Label("Agent activity", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Open this resident’s overview to choose saved activity, or open its chat to use workspace tools.")
                } actions: {
                    Button("Open overview") { world.openAgentProfile() }
                }
            }
        } else if world.activatingConversation || world.preparingConversation {
            VStack(spacing: 12) { ProgressView(); Text("Opening your conversation…").foregroundStyle(palette.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSelectedConversationActive {
            WorkspaceView(sidebarVisible: true, showSidebar: {}, presentsAgentOverview: false,
                          openAgentOverview: { world.openAgentProfile() })
                .accessibilityIdentifier("agentWorld.workspace.chat")
        } else {
            ContentUnavailableView {
                Label(world.selectedProfile == nil ? "Meet an agent" : world.selectedSessionID == nil ? "Start a chat" : "Resume this conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(world.error ?? (world.selectedProfile == nil
                    ? "Select a resident to open their full Locus workspace. Crew Chat is available alongside every agent."
                    : "Another conversation is active in Locus. Resume \(world.selectedProfile?.name ?? "this agent") here to use its chat and controls."))
            } actions: {
                if world.selectedProfile != nil {
                    Button("New chat", action: world.newConversation)
                        .buttonStyle(.borderedProminent)
                        .disabled(!world.canStartConversation(for: world.selection ?? ""))
                        .accessibilityIdentifier("agentWorld.workspace.newChat")
                    Button(ocean ? "Open Vivre card" : "Agent details") { world.openAgentProfile() }
                        .accessibilityIdentifier("agentWorld.workspace.openProfile")
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
