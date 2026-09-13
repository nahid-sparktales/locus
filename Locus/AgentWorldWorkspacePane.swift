import SwiftUI

/// The map chooses a resident; the existing Locus workspace owns every chat,
/// approval and task action. The pinned identity guard prevents a different
/// foreground chat from silently becoming this resident's conversation.
struct AgentWorldWorkspacePane: View {
    @ObservedObject var world: AgentWorldModel
    @ObservedObject var model: AppModel
    let title: String
    @State private var showsDetails = false

    private enum Pane: String, CaseIterable { case chat = "Chat", details = "Agent details", crew = "Crew Chat" }
    private var selectedPane: Binding<Pane> {
        Binding(get: { world.sharedChatPresented ? .crew : showsDetails ? .details : .chat }, set: { pane in
            if pane == .crew { world.openSharedChat() }
            else {
                world.sharedChatPresented = false
                showsDetails = pane == .details
                if isSelectedConversationActive {
                    if pane == .details { model.selectInspectorTab(.agent) }
                } else { world.activateSelectedConversation() }
            }
        })
    }
    private var isSelectedConversationActive: Bool {
        world.selectedSessionID != nil && world.selectedSessionID == model.currentSessionID
            && SessionSummary.canonicalWorkspacePath(model.workspacePath) == world.workspace
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Picker("Workspace pane", selection: selectedPane) {
                    ForEach(Pane.allCases, id: \.self) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityIdentifier("agentWorld.workspace.tabs")
                Divider()
                paneContent(width: proxy.size.width)
            }
            .environment(\.locusWorkspaceGeometry, WorkspaceGeometrySnapshot(
                windowSize: proxy.size, workspaceWidth: proxy.size.width,
                workspaceHeight: max(0, proxy.size.height - 110), composerWidth: proxy.size.width
            ))
        }
        .background(LocusTheme.panel)
        .onChange(of: world.selection) { _, _ in showsDetails = false }
        .onChange(of: model.currentSessionID) { _, _ in world.adoptForegroundConversation() }
        .onChange(of: world.activatingConversation) { _, activating in
            if !activating, showsDetails, isSelectedConversationActive { model.selectInspectorTab(.agent) }
        }
        .onChange(of: model.inspectorTab) { _, _ in
            if model.agentWorldOwnsPresentations, isSelectedConversationActive,
               !world.activatingConversation, !world.sharedChatPresented, !model.inspectorCollapsed {
                showsDetails = true
            }
        }
        .accessibilityIdentifier("agentWorld.workspace")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: world.theme == "grand-line" ? "safari" : "square.stack.3d.up")
                .font(.locus(size: 18, weight: .medium))
                .foregroundStyle(world.theme == "grand-line" ? LocusTheme.warning : LocusTheme.signal)
                .frame(width: 38, height: 38)
                .background(LocusTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.locus(size: 15, weight: .semibold))
                Text(world.sharedChatPresented ? "Your crew, in one conversation" : world.conversationContext ?? world.selectedProfile?.name ?? "Choose an agent to get started")
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let profile = world.selectedProfile {
                Menu {
                    Button("New conversation", action: world.newConversation).disabled(world.conversationBusy)
                    Divider()
                    Button("Edit agent…") { model.presentSavedAgentEditor(profile) }
                    Button("Manage agent…") { model.manageSavedAgent(profile) }
                } label: { Image(systemName: "ellipsis.circle").font(.locus(size: 15)) }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(!world.canInteract || !isSelectedConversationActive)
                .accessibilityLabel("Agent actions")
                .accessibilityIdentifier("agentWorld.workspace.actions")
            }
            Button(action: world.dismissConversation) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.locus(.icon)).help("Return to the world")
                .accessibilityIdentifier("agentWorld.closeConversation")
        }.padding(16)
    }

    @ViewBuilder
    private func paneContent(width: CGFloat) -> some View {
        if world.sharedChatPresented {
            AgentWorldCrewPane(world: world, crew: model.agentCrewChat)
        } else if !world.canInteract {
            ContentUnavailableView("Interaction unavailable", systemImage: "lock", description: Text("This world's access to agent conversations is no longer available."))
        } else if world.activatingConversation || (world.selectedProfile != nil && world.selectedSessionID == nil && world.error == nil) {
            VStack(spacing: 12) { ProgressView(); Text("Opening your conversation…").foregroundStyle(LocusTheme.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSelectedConversationActive {
            if showsDetails {
                HStack(spacing: 0) {
                    InspectorView(resizeWidth: max(300, width - InspectorRail.width))
                    InspectorRail()
                }
                .accessibilityIdentifier("agentWorld.workspace.inspector")
            } else {
                WorkspaceView(sidebarVisible: true, showSidebar: {})
                    .accessibilityIdentifier("agentWorld.workspace.chat")
            }
        } else {
            ContentUnavailableView {
                Label(world.selectedProfile == nil ? "Meet an agent" : "Resume this conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(world.error ?? (world.selectedProfile == nil
                    ? "Select a resident to open their full Locus workspace. Crew Chat is available alongside every agent."
                    : "Another conversation is active in Locus. Resume \(world.selectedProfile?.name ?? "this agent") here to use its chat and controls."))
            } actions: {
                if world.selectedProfile != nil {
                    Button("Resume conversation", action: world.activateSelectedConversation)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("agentWorld.workspace.resume")
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
