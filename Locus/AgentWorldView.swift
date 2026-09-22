import SwiftUI
import ImageIO

struct AgentWorldCommands: Commands {
    @ObservedObject var model: AgentWorldModel
    var body: some Commands {
        CommandMenu("Work") {
            ForEach(model.availableScreens) { screen in
                Button(screen.screen.title + "…") { model.open(pluginID: screen.pluginID, screenID: screen.screen.id) }
                    .accessibilityIdentifier("menu.pluginScreen.\(screen.id)")
            }
        }
    }
}

struct AgentWorldView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @ObservedObject var model: AgentWorldModel

    var body: some View {
        Group {
            if let appModel = model.appModel {
                AgentWorldHub(model: model, appModel: appModel)
                    .modifier(LocusSharedPresentations(surface: .agentWorld, updates: appModel.appUpdates))
                    .appFeatureEnvironment(from: appModel)
                    .tint(model.theme == "grand-line" ? viewColors.warning : appModel.accentActionColor)
            } else {
                AgentWorldHub(model: model, appModel: nil)
            }
        }
        .environment(\.locusOceanTheme, model.theme == "grand-line")
        .environment(\.locusCaptainDeckTheme, model.usesWoodQuarters)
        .transformEnvironment(\.colorScheme) { scheme in if model.theme == "grand-line" { scheme = .dark } }
        .background(model.theme == "grand-line" ? Color(nsColor: LocusTheme.oceanPalette.paper) : viewColors.paper)
        .locusSheet(item: $model.selectedTransfer) { transfer in
            AgentWorldTransferDetail(world: model, transfer: transfer)
        }
        .locusSheet(item: $model.newAgentDraft) { profile in
            if let appModel = model.appModel {
                AgentProfileEditor(profile: profile, isNew: true,
                    existingProfiles: appModel.agentProfiles, onSave: model.saveNewAgent)
                    .environmentObject(appModel)
                    .appFeatureEnvironment(from: appModel)
                    .modifier(LocusWorldSheetTheme())
                    .environment(\.locusOceanTheme, model.theme == "grand-line")
                    .environment(\.locusCaptainDeckTheme, model.usesWoodQuarters)
            }
        }
        .modifier(LocusWorldSheetTheme())
        .environment(\.locusOceanTheme, model.theme == "grand-line")
        .environment(\.locusCaptainDeckTheme, model.usesWoodQuarters)
        .accessibilityIdentifier("agentWorld.window")
    }
}

/// A modal workspace inside the world window keeps all of the existing native
/// editors and approval sheets attached to the same presentation owner.
private struct AgentWorldHub: View {
    @ObservedObject var model: AgentWorldModel
    let appModel: AppModel?

    var body: some View {
        ZStack {
            AgentWorldSurface(model: model, appModel: appModel)
                .allowsHitTesting(!model.quartersPresented)
                .accessibilityHidden(model.quartersPresented)
            if model.quartersPresented {
                Color.black.opacity(0.48).ignoresSafeArea()
                    .accessibilityHidden(true)
                AgentWorldSurface(model: model, appModel: appModel, isQuarters: true)
                    .frame(maxWidth: 1440, maxHeight: 1000)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18)
                        .stroke(AgentWorldPalette(ocean: model.theme == "grand-line").line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .padding(20)
                    .onExitCommand { model.quartersPresented = false }
                    .accessibilityIdentifier("agentWorld.quarters")
            }
        }
    }
}

private struct AgentWorldTransferDetail: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @ObservedObject var world: AgentWorldModel
    let transfer: AgentWorldTransfer
    @Environment(\.dismiss) private var dismiss

    private func name(_ id: String) -> String {
        world.residents.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name ?? "Unavailable agent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Label("Agent handoff", systemImage: "arrow.triangle.branch")
                    .font(.locus(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.locus(.icon)).help("Close handoff details")
            }
            Text(transfer.title).font(.locus(size: 19, weight: .semibold))
            HStack(spacing: 10) {
                Text(name(transfer.fromAgentID))
                Image(systemName: "arrow.right").foregroundStyle(viewColors.muted)
                Text(name(transfer.toAgentID))
            }.font(.locus(size: 12, weight: .medium))
            Text(transfer.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.locus(size: 10)).foregroundStyle(viewColors.muted)
            Divider()
            ScrollView {
                Text(transfer.detail).font(.locus(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            HStack {
                Spacer()
                Button("Open receiving conversation") { world.showTransferConversation(transfer) }
                    .buttonStyle(.borderedProminent).disabled(!world.canInteract)
                    .accessibilityIdentifier("agentWorld.transfer.openConversation")
            }
        }
        .padding(24).frame(width: 520)
        .foregroundStyle(viewColors.ink).background(viewColors.panel)
        .accessibilityIdentifier("agentWorld.transfer.details")
    }
}

private struct AgentWorldSurface: View {
    @ObservedObject var model: AgentWorldModel
    let appModel: AppModel?
    var isQuarters = false
    @State private var search = ""
    @State private var showsResidents = true
    @State private var showsWorld = true
    @State private var showsActivity = false
    @State private var deckPage: DeckPage = .agents
    @State private var boardCard: BoardCard?
    @State private var availableWidth: CGFloat = 1280
    private enum DeckPage { case agents, board, calendar }
    private var ocean: Bool { model.theme == "grand-line" }
    private var palette: AgentWorldPalette { .init(ocean: ocean, deck: isQuarters && model.usesWoodQuarters) }
    private var workspaceTitle: String { isQuarters && ocean ? "Captain’s Quarters" : "Agent workspace" }
    private var filteredResidents: [AgentWorldResident] {
        model.residents.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.role.localizedCaseInsensitiveContains(search)
                || model.residentPlacements[$0.id]?.ship.localizedCaseInsensitiveContains(search) == true
                || model.residentPlacements[$0.id]?.home.localizedCaseInsensitiveContains(search) == true
        }
    }
    private var workingCount: Int { model.residents.filter { $0.status == "working" }.count }
    private var attentionCount: Int { model.attentionRequests.count }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(palette.line).frame(height: 1)
            HSplitView {
                if showsResidents || model.graphicsError != nil {
                    residentsPanel.clipShape(RoundedRectangle(cornerRadius: isQuarters ? 12 : 0))
                }
                if !isQuarters && (showsWorld || !model.conversationPresented || model.quartersPresented) { worldCanvas }
                if isQuarters {
                    VStack(spacing: 0) {
                        deckNavigation
                        if deckPage != .agents { deckTool }
                        else if model.conversationPresented { agentWorkspace }
                        else { quartersWelcome }
                    }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if model.conversationPresented && (isQuarters || !model.quartersPresented) {
                    agentWorkspace
                }
            }.padding(isQuarters && ocean ? 16 : 0)
        }
        .foregroundStyle(palette.ink)
        .background {
            if isQuarters && ocean {
                GeometryReader { geometry in
                    Image("CaptainDeck").resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .overlay(Color.black.opacity(0.16))
                }.allowsHitTesting(false).accessibilityHidden(true)
            } else { palette.paper }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        availableWidth = width
                        if model.conversationPresented && width < 1340 { showsWorld = false }
                        if isQuarters && model.conversationPresented && !model.profilePresented && width < 1100 { showsResidents = false }
                    }
            }
        }
        .onChange(of: model.conversationPresented) { _, presented in
            if !presented { showsWorld = true }
            else if availableWidth < 1340 { showsWorld = false }
        }
        .onChange(of: model.profilePresented) { _, presented in
            if isQuarters && !presented && model.conversationPresented && availableWidth < 1100 { showsResidents = false }
        }
        .onChange(of: model.selection) { _, _ in if isQuarters { deckPage = .agents } }
        .onChange(of: model.selectedSessionID) { _, _ in if isQuarters { deckPage = .agents } }
        .onChange(of: model.activityCenterRequest) { _, _ in
            if isQuarters == model.quartersPresented { showsActivity = true }
        }
        .locusSheet(isPresented: $showsActivity) {
            if let appModel {
                AgentWorldActivityPane(activity: appModel.activity)
                    .appFeatureEnvironment(from: appModel)
            }
        }
        .locusSheet(item: $boardCard) { card in
            AgentWorldBoardChatPicker(world: model, card: card) { deckPage = .agents; boardCard = nil }
        }
    }

    @ViewBuilder private var agentWorkspace: some View {
        if let appModel {
            AgentWorldWorkspacePane(world: model, model: appModel, title: workspaceTitle)
                .frame(minWidth: 450, idealWidth: 620, maxWidth: .infinity)
        } else {
            ContentUnavailableView("Connect to Locus", systemImage: "bubble.left.and.bubble.right",
                description: Text("Agent conversations are available when this world is connected to the Locus workspace."))
        }
    }

    private var deckNavigation: some View {
        HStack(spacing: 8) {
            Button { showsResidents.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: showsResidents))
                .help(showsResidents ? "Hide crew list" : "Show crew list")
                .accessibilityLabel(showsResidents ? "Hide crew list" : "Show crew list")
                .accessibilityIdentifier("agentWorld.quarters.toggleCrew")
            Button { deckPage = .agents; model.dismissConversation() } label: { Label("Crew overview", systemImage: "person.3") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: deckPage == .agents))
            Button { openDeckTool(.board) } label: { Label("Task board", systemImage: "rectangle.split.3x1") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: deckPage == .board))
                .accessibilityIdentifier("agentWorld.quarters.board")
            Button { openDeckTool(.calendar) } label: { Label("Calendar", systemImage: "calendar") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: deckPage == .calendar))
                .accessibilityIdentifier("agentWorld.quarters.calendar")
            Spacer(minLength: 0)
            if ocean {
                Menu {
                    Section("Captain’s Quarters appearance") {
                        ForEach(AgentWorldQuartersAppearance.allCases) { appearance in
                            Button { model.setQuartersAppearance(appearance) } label: {
                                if model.quartersAppearance == appearance { Label(appearance.title, systemImage: "checkmark") }
                                else { Text(appearance.title) }
                            }
                        }
                    }
                } label: { Label("Settings", systemImage: "gearshape") }
                    .menuStyle(.borderlessButton).fixedSize().font(.locus(size: 12))
                    .accessibilityLabel("Captain’s Quarters settings")
                    .accessibilityIdentifier("agentWorld.quarters.settings")
            }
            Menu {
                Button("Connections") { openManagement(.sources) }
                Button("Automations & schedules") { openManagement(.agents) }
                Divider()
                Button("Library") { appModel?.openLibrary() }
                Button("Identity Vault") { appModel?.identityVault.open() }
            } label: { Label("More", systemImage: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().font(.locus(size: 12))
                .accessibilityLabel("Connections and more tools")
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(palette.panel.opacity(isQuarters && ocean ? 0.93 : 1)).overlay(alignment: .bottom) { palette.line.frame(height: 1) }
    }

    private func openDeckTool(_ page: DeckPage) {
        if model.conversationPresented && !model.profilePresented && !model.sharedChatPresented,
           model.selectedSessionID == appModel?.currentSessionID {
            deckPage = .agents
            appModel?.selectInspectorTab(page == .calendar ? .calendar : .board)
            model.workspaceToolsRequest += 1
        } else { deckPage = page }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: ocean ? "safari" : "folder")
                .font(.locus(size: 16, weight: .medium)).foregroundStyle(ocean ? palette.warning : palette.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(isQuarters ? workspaceTitle : model.projectName)
                    .font(.locus(size: isQuarters ? 21 : 14, weight: .semibold, design: isQuarters && ocean ? .serif : .default))
                    .lineLimit(1).truncationMode(.middle)
                if isQuarters {
                    Text("\(model.projectName) · Your crew and their work")
                        .font(.locus(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                }
            }.frame(minWidth: 60, alignment: .leading)
            Spacer(minLength: 10)
            if !isQuarters { Menu {
                ForEach(model.availableThemes) { theme in
                    Button {
                        model.setTheme(theme.id)
                    } label: {
                        if theme.id == model.theme { Label(theme.name, systemImage: "checkmark") }
                        else { Text(theme.name) }
                    }
                }
            } label: {
                Label(model.availableThemes.first(where: { $0.id == model.theme })?.name ?? "World", systemImage: ocean ? "globe.americas.fill" : "globe")
                    .font(.locus(size: 11, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).frame(minWidth: 100, idealWidth: 160, maxWidth: 190)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(palette.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1))
            .disabled(model.activeScreen?.screen.capabilities.contains("world.preferences") != true)
            .accessibilityLabel("Choose a world")
            .accessibilityIdentifier("agentWorld.themePicker")
            }
            if !ocean && !isQuarters {
                Menu {
                    ForEach(["mixed", "pandas", "explorers"], id: \.self) { style in
                        Button { model.setResidentStyle(style) } label: {
                            if style == model.residentStyle { Label(style.capitalized, systemImage: "checkmark") }
                            else { Text(style.capitalized) }
                        }
                    }
                } label: { Label("Appearance", systemImage: "person.crop.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.activeScreen?.screen.capabilities.contains("world.preferences") != true)
                .accessibilityIdentifier("agentWorld.appearance")
            }
            if model.conversationPresented && !isQuarters {
                Button {
                    if !showsWorld && availableWidth < 1020 { showsResidents = false }
                    showsWorld.toggle()
                } label: {
                    Image(systemName: showsWorld ? "arrow.up.left.and.arrow.down.right" : "globe")
                }
                .buttonStyle(AgentWorldChromeButtonStyle())
                .help(showsWorld ? "Expand \(workspaceTitle)" : "Show the world beside your workspace")
                .accessibilityLabel(showsWorld ? "Expand workspace" : "Show world")
                .accessibilityIdentifier("agentWorld.toggleWorld")
            }
            Button(action: model.createAgent) { Label("New Agent", systemImage: "plus") }
                .buttonStyle(AgentWorldChromeButtonStyle())
                .disabled(!model.canCreateAgent)
                .accessibilityIdentifier("agentWorld.newAgent")
            Button { deckPage = .agents; model.openSharedChat() } label: { Label("Crew Chat", systemImage: "bubble.left.and.bubble.right") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: model.sharedChatPresented))
                .disabled(!model.canInteract || appModel == nil)
                .accessibilityIdentifier("agentWorld.crewChat")
            if isQuarters {
                Button { model.quartersPresented = false } label: { Label("Return to world", systemImage: "xmark") }
                    .buttonStyle(AgentWorldChromeButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("agentWorld.quarters.close")
            } else {
                Button { model.openAgentControls() } label: {
                    Label(ocean ? "Captain’s Quarters" : "Agent workspace", systemImage: "person.text.rectangle")
                }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: true))
                .disabled(!model.canInteract)
                .accessibilityIdentifier("agentWorld.openQuarters")
                Button { showsResidents.toggle() } label: { Label("Agents", systemImage: "person.3") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: showsResidents))
                .accessibilityIdentifier("agentWorld.toggleResidents")
            }
        }
        .font(.locus(size: 11, weight: .medium))
        .controlSize(.small).padding(.horizontal, isQuarters ? 24 : 18).frame(height: isQuarters ? 94 : 56)
        .background {
            if isQuarters && ocean { palette.paper.opacity(0.78) }
            else { palette.panel }
        }
    }

    private var worldCanvas: some View {
        ZStack {
            palette.paper
            if let screen = model.activeScreen { PluginScreenHost(model: model, screen: screen).id(screen.id + (screen.digest ?? "")) }
            if let error = model.graphicsError {
                VStack(spacing: 10) {
                    Image(systemName: "map").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 340)
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agentWorld.world")
    }

    private var residentsPanel: some View {
        VStack(spacing: 0) {
            if isQuarters, let appModel {
                VStack(spacing: 5) {
                    compactResidentAction("Manage Accounts", icon: "person.crop.circle") { appModel.presentSettings(.accounts) }
                    compactResidentAction("Manage Plugins", icon: "puzzlepiece.extension") { appModel.presentSettings(.extensions) }
                    compactResidentAction("Manage Agents", icon: "gearshape.2") {
                        openManagement(.agents)
                    }
                    compactResidentAction("Connections", icon: "point.3.connected.trianglepath.dotted") { openManagement(.sources) }
                }.padding(12)
                Rectangle().fill(palette.line).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agents").font(.locus(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(model.residents.count)").font(.locus(size: 10, weight: .semibold)).foregroundStyle(palette.warning)
                }
                Text("\(workingCount) working · \(attentionCount) need attention")
                    .font(.locus(size: 11)).foregroundStyle(palette.muted)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField("Search agents", text: $search)
                        .textFieldStyle(.plain).accessibilityIdentifier("agentWorld.residentSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.muted) }
                            .buttonStyle(.locus(.icon)).accessibilityLabel("Clear resident search")
                    }
                }
                .font(.locus(size: 12)).padding(8).background(palette.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
            }.padding(12)
            Rectangle().fill(palette.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.residents.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: ocean ? "sailboat" : "person.crop.square.badge.plus")
                                .font(.locus(size: 30)).foregroundStyle(palette.warning)
                            Text(ocean ? "Your adventure starts here" : "No saved agents")
                                .font(.locus(size: 13, weight: .semibold))
                            Text("Create an agent to give it a home in this world.")
                                .font(.locus(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
                            Button("Create an agent", action: model.createAgent)
                                .buttonStyle(AgentWorldChromeButtonStyle(selected: true))
                                .disabled(!model.canCreateAgent)
                                .accessibilityIdentifier("agentWorld.empty.newAgent")
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if filteredResidents.isEmpty {
                        Text("No agents match your search.")
                            .font(.locus(size: 11)).foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(filteredResidents) { resident in residentRow(resident) }
                    }
                }.padding(10)
            }
            Rectangle().fill(palette.line).frame(height: 1)
            if ocean && !isQuarters {
                Label("Glowing ship: traveling to work. Lit island: working ashore.", systemImage: "sparkles")
                    .font(.locus(size: 11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
            VStack(spacing: 5) {
                compactResidentAction("Crew Chat", icon: "bubble.left.and.bubble.right") { deckPage = .agents; model.openSharedChat() }
                    .disabled(!model.canInteract || appModel == nil)
                    .accessibilityIdentifier("agentWorld.residents.crewChat")
                if !isQuarters {
                compactResidentAction(ocean ? "Captain’s Quarters" : "Agent workspace", icon: "person.text.rectangle") { model.openAgentControls() }
                    .disabled(!model.canInteract)
                    .accessibilityIdentifier("agentWorld.residents.quarters")
                }
                compactResidentAction("Activity Center", icon: "bell", badge: attentionCount,
                                      action: model.requestActivityCenter)
                    .help("Review live tasks, approvals, results, and activity across your chats")
                    .disabled(appModel == nil)
                    .accessibilityIdentifier("agentWorld.residents.activityCenter")
            }.padding(9)
            HStack(spacing: 5) {
                Circle().fill(model.canInteract ? palette.success : palette.muted).frame(width: 4, height: 4)
                Text(model.canInteract ? "Connected" : "World preview")
                Spacer()
                Text(ocean ? "LOCAL LINE" : "OUTPOST").tracking(1)
            }.font(.locus(size: 8)).foregroundStyle(palette.muted).padding(.horizontal, 12).padding(.vertical, 9)
                .background(palette.paper.opacity(0.5))
        }
        .frame(minWidth: 215, idealWidth: 238, maxWidth: 290)
        .background(palette.panel.opacity(isQuarters && ocean ? 0.94 : 1))
        .accessibilityIdentifier("agentWorld.residents")
    }

    private func residentRow(_ resident: AgentWorldResident) -> some View {
        let selected = model.selection == resident.id
        let placement = model.residentPlacements[resident.id]
        return VStack(spacing: 0) {
            Button { deckPage = .agents; model.openAgentProfile(resident.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    if let id = UUID(uuidString: resident.id), let appModel {
                        AgentWorldResidentPortrait(world: model, resident: resident, agentTeams: appModel.agentTeamsModel, profileID: id)
                            .frame(width: 44, height: 48)
                    } else if ocean {
                        AgentWorldShipPortrait(world: model, resident: resident)
                            .frame(width: 44, height: 48)
                            .background(palette.paper, in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
                    } else {
                        Image(systemName: "person.crop.circle").font(.locus(size: 26, weight: .light))
                            .foregroundStyle(palette.signal).frame(width: 36, height: 42)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resident.name).font(.locus(size: 12, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        Text(placement?.ship ?? resident.role.capitalized)
                            .font(.locus(size: 10)).foregroundStyle(palette.muted).lineLimit(1)
                        if let placement {
                            Label(placement.home, systemImage: "mappin").font(.locus(size: 9)).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(AgentWorldChrome.statusColor(resident.status)).frame(width: 5, height: 5)
                            Text(AgentWorldChrome.statusLabel(resident.status, ocean: ocean)).font(.locus(size: 11, weight: .medium))
                        }.foregroundStyle(AgentWorldChrome.statusColor(resident.status)).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "chevron.right").font(.locus(size: 9, weight: .semibold)).foregroundStyle(palette.warning).padding(.top, 7) }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.locus(.card))
            .help(resident.detail ?? "Open \(resident.name)’s overview, chats, and automations")
            .accessibilityLabel("\(resident.name), \(placement.map { "\($0.ship), \($0.home), " } ?? "")\(resident.role), \(AgentWorldChrome.statusLabel(resident.status, ocean: ocean))")
            .accessibilityIdentifier("agentWorld.resident.\(resident.id)")
            HStack(spacing: 7) {
                Button { deckPage = .agents; model.newConversation(for: resident.id) } label: {
                    Label("New chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.locus(.quiet)).disabled(!model.canStartConversation(for: resident.id))
                .accessibilityLabel("New chat with \(resident.name)")
                .accessibilityIdentifier("agentWorld.residentNewChat.\(resident.id)")
                Spacer(minLength: 0)
                if ocean {
                    Menu { AgentWorldShipStyleOptions(world: model, agentID: resident.id) } label: { Text("Ship") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(model.activeScreen?.screen.capabilities.contains("world.preferences") != true)
                        .accessibilityLabel("Ship style for \(resident.name)")
                        .accessibilityIdentifier("agentWorld.residentShipStyle.\(resident.id)")
                }
                Menu {
                    Button("Agent overview") { model.openAgentProfile(resident.id) }
                    if let profile = appModel?.agentProfiles.first(where: { $0.id.uuidString == resident.id }) {
                        Button("Edit agent…") { appModel?.presentSavedAgentEditor(profile) }
                        Button("Manage agent…") { appModel?.manageSavedAgent(profile, workspace: model.workspace) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 16, height: 20) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!model.canInteract)
                .accessibilityLabel("Actions for \(resident.name)")
                .accessibilityIdentifier("agentWorld.residentActions.\(resident.id)")
            }
            .font(.locus(size: 11, weight: .medium)).foregroundStyle(palette.warning)
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .background(selected ? palette.white : .clear, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? palette.warning.opacity(0.5) : .clear, lineWidth: 1))
    }

    private func compactResidentAction(_ title: String, icon: String, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(palette.warning).frame(width: 16)
                Text(title).font(.locus(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge)").font(.locus(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(palette.warning)
                } else { Image(systemName: "chevron.right").font(.locus(size: 8)).foregroundStyle(palette.muted) }
            }.padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 32)
        }
        .buttonStyle(.locus(.card))
        .background(palette.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.line, lineWidth: 1))
    }

    private var quartersWelcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    Label(ocean ? "WELCOME ABOARD" : "YOUR WORKSPACE", systemImage: ocean ? "sun.max" : "person.3")
                        .font(.locus(size: 11, weight: .semibold)).tracking(2).foregroundStyle(palette.warning)
                    Text(ocean ? "All hands on deck" : "Your agents")
                        .font(.system(size: 30, weight: .semibold, design: ocean ? .serif : .default))
                    Text("Choose a crewmate to open their overview, or start a chat with tools at your side.")
                        .font(.locus(size: 13)).foregroundStyle(palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Label("\(model.residents.count) agents", systemImage: "person.3")
                        Label("\(workingCount) working", systemImage: "sparkles")
                        Label("\(attentionCount) need you", systemImage: "bell")
                    }.font(.locus(size: 11, weight: .medium)).foregroundStyle(palette.inkSoft).padding(.top, 4)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.warning.opacity(0.3), lineWidth: 1))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(filteredResidents) { resident in
                        crewCard(resident)
                    }
                }
                if filteredResidents.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Your crew starts here" : "No matching agents",
                        systemImage: "person.3", description: Text(search.isEmpty ? "Create your first agent to give it a ship and a place on your deck." : "Try another name or clear the search."))
                        .background(palette.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(20)
        }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("agentWorld.quarters.crewOverview")
    }

    private func crewCard(_ resident: AgentWorldResident) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.openAgentProfile(resident.id) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let appModel, let id = UUID(uuidString: resident.id) {
                            AgentWorldResidentPortrait(world: model, resident: resident, agentTeams: appModel.agentTeamsModel, profileID: id)
                                .frame(width: 48, height: 48)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(resident.name).font(.locus(size: 17, weight: .semibold)).foregroundStyle(palette.ink)
                            Text(model.residentPlacements[resident.id]?.ship ?? resident.role.capitalized)
                                .font(.locus(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(palette.warning)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(AgentWorldChrome.statusColor(resident.status)).frame(width: 6, height: 6)
                        Text(AgentWorldChrome.statusLabel(resident.status, ocean: ocean))
                            .font(.locus(size: 12, weight: .medium)).foregroundStyle(palette.inkSoft)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open \(resident.name)’s overview")
            Rectangle().fill(palette.line).frame(height: 1)
            HStack {
                Button("Overview") { model.openAgentProfile(resident.id) }
                    .buttonStyle(AgentWorldChromeButtonStyle())
                Spacer()
                Button { model.newConversation(for: resident.id) } label: { Label("Chat", systemImage: "bubble.left") }
                    .buttonStyle(AgentWorldChromeButtonStyle(selected: true))
                    .disabled(!model.canStartConversation(for: resident.id))
            }
        }.padding(18).background(palette.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.warning.opacity(0.28), lineWidth: 1))
            .accessibilityIdentifier("agentWorld.crewCard.\(resident.id)")
    }

    private func openManagement(_ tab: ConfigureAgentTab) {
        guard let appModel else { return }
        appModel.presentConfigureAgent(draftText: "")
        appModel.configureAgentWorkspace = model.workspace
        appModel.configureAgentProfileID = nil
        appModel.configureAgentTab = tab
    }

    private var deckTool: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: deckPage == .calendar ? "calendar" : "rectangle.split.3x1")
                    .font(.locus(size: 22)).foregroundStyle(palette.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(deckPage == .calendar ? "Calendar" : "Task board").font(.locus(size: 22, weight: .semibold))
                    Text(deckPage == .calendar ? "Your built-in calendar, with connected calendars layered on top" : "Shared work for \(model.projectName)")
                        .font(.locus(size: 12)).foregroundStyle(palette.muted)
                }
                Spacer()
                Button("Agent overview") { deckPage = .agents }
                    .buttonStyle(AgentWorldChromeButtonStyle())
            }.padding(20)
            Divider()
            if deckPage == .calendar { InspectorCalendarTab() }
            else {
                InspectorBoardTab(store: BoardStore.shared(workspacePath: model.workspace), isDetached: true,
                                  workInChatOverride: { boardCard = $0 })
                    .id(BoardStore.storageIdentity(workspacePath: model.workspace))
            }
        }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity).background(palette.paper)
    }
}

private struct AgentWorldBoardChatPicker: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @ObservedObject var world: AgentWorldModel
    let card: BoardCard
    let didOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profileID: String = ""
    @State private var opening = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Work on this with an agent").font(.locus(size: 21, weight: .semibold))
            Text(card.title).font(.locus(size: 14, weight: .medium))
            Picker("Agent", selection: $profileID) {
                Text("Choose an agent").tag("")
                ForEach(world.residents) { resident in Text(resident.name).tag(resident.id) }
            }
            Text("Opens a new chat in this project with the card ready to send.")
                .font(.locus(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).font(.locus(size: 12)).foregroundStyle(viewColors.warning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(opening)
                Spacer()
                if opening { ProgressView().controlSize(.small) }
                Button("Open chat") {
                    opening = true; error = nil
                    Task { @MainActor in
                        do {
                            try await world.openBoardCard(card, profileID: profileID)
                            didOpen()
                        } catch { self.error = error.localizedDescription }
                        opening = false
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(opening || !world.canStartConversation(for: profileID))
            }
        }.padding(26).frame(width: 440)
            .onAppear { profileID = world.selection ?? "" }
            .interactiveDismissDisabled(opening)
            .accessibilityIdentifier("agentWorld.board.chooseAgent")
    }
}

private struct AgentWorldResidentPortrait: View {
    @ObservedObject var world: AgentWorldModel
    let resident: AgentWorldResident
    @ObservedObject var agentTeams: AgentTeamsModel
    let profileID: UUID

    var body: some View {
        if agentTeams.agentAvatarData[profileID] != nil || world.theme != "grand-line" {
            AgentAvatarView(profileID: profileID, name: resident.name, size: 44)
        } else {
            AgentWorldShipPortrait(world: world, resident: resident)
                .background(AgentWorldPalette(ocean: true, deck: world.usesWoodQuarters).paper, in: RoundedRectangle(cornerRadius: 9))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct AgentWorldShipPortrait: View {
    @ObservedObject var world: AgentWorldModel
    let resident: AgentWorldResident
    @State private var portrait: NSImage?
    private var style: String? {
        world.shipStyles[resident.id] ?? AgentWorldShipStyle.all.first {
            $0.name == world.residentPlacements[resident.id]?.ship
        }?.id
    }
    private var identity: String { (world.activeScreen?.root ?? "") + (world.activeScreen?.digest ?? "") + (style ?? "") }

    var body: some View {
        Group {
            if let portrait { Image(nsImage: portrait).resizable().scaledToFit().padding(1) }
            else {
                Text(String(resident.name.prefix(1))).font(.locus(size: 23, weight: .medium, design: .serif))
                    .foregroundStyle(AgentWorldPalette(ocean: true, deck: world.usesWoodQuarters).warning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: identity) {
            portrait = nil
            guard let screen = world.activeScreen, let style, AgentWorldShipStyle.isSupported(style) else { return }
            portrait = AgentWorldPortraitCache.image(screen: screen, style: style)
        }
    }
}

@MainActor
private enum AgentWorldPortraitCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 45; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    static func image(screen: AgentWorldModel.AvailableScreen, style: String) -> NSImage? {
        let key = (screen.root + (screen.digest ?? "") + style) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let expanded = ["ship_mihawk_coffin", "ship_garp_battleship", "ship_marine_patrol"].contains(style)
        let name = expanded ? style : String(style.dropFirst("ship_".count))
        let directory = (screen.screen.entrypoint as NSString).deletingLastPathComponent
        let relative = (directory.isEmpty ? "" : directory + "/") + "themes/grand-line/references/" + name + ".jpg"
        guard let file = try? PluginScreenFiles.file(root: URL(fileURLWithPath: screen.root), path: relative),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        images.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}

/// Shared native chrome follows the same palette as the chart and quarters.
enum AgentWorldChrome {
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "working": LocusTheme.success
        case "needs_attention", "queued": LocusTheme.warning
        case "failed": LocusTheme.danger
        case "completed": LocusTheme.blue
        default: LocusTheme.muted
        }
    }
    static func statusLabel(_ status: String, ocean: Bool) -> String {
        switch status {
        case "working": "Working"
        case "needs_attention": "Needs you"
        case "queued": "Queued"
        case "failed": "Needs attention"
        case "completed": "Completed"
        default: "Available"
        }
    }
}

struct AgentWorldChromeButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.locusOceanTheme) private var ocean
    @Environment(\.locusCaptainDeckTheme) private var deck
    private var palette: AgentWorldPalette { .init(ocean: ocean, deck: deck) }
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.locus(size: 11, weight: .medium))
            .foregroundStyle(selected ? palette.warning : palette.inkSoft)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background((selected ? palette.warning.opacity(0.12) : palette.white.opacity(0.55)), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? palette.warning.opacity(0.35) : palette.line, lineWidth: 1))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

/// Explicit colors keep the nautical chrome independent of AppKit appearance normalization.
typealias AgentWorldPalette = LocusViewColors

struct AgentWorldShipStyleOptions: View {
    @ObservedObject var world: AgentWorldModel
    let agentID: String
    var body: some View {
        Button { world.setShipStyle(agentID: agentID, style: nil) } label: {
            if world.shipStyles[agentID] == nil { Label("Automatic", systemImage: "checkmark") }
            else { Text("Automatic") }
        }
        Divider()
        ForEach(AgentWorldShipStyle.all) { style in
            Button { world.setShipStyle(agentID: agentID, style: style.id) } label: {
                if world.shipStyles[agentID] == style.id { Label(style.name, systemImage: "checkmark") }
                else { Text(style.name) }
            }
        }
    }
}

/// Uses the same live inbox, run controls and results as the regular workspace.
private struct AgentWorldActivityPane: View {
    @ObservedObject var activity: ActivityCenterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ActivityCenterView()
            .frame(minWidth: 480, idealWidth: 600, minHeight: 500, idealHeight: 700)
            .onChange(of: activity.activityCenterPresented) { _, presented in
                if !presented { dismiss() }
            }
            .onDisappear { activity.activityCenterPresented = false }
            .accessibilityIdentifier("agentWorld.activityCenter")
    }
}
