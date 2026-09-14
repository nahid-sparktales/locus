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
    @ObservedObject var model: AgentWorldModel

    var body: some View {
        Group {
            if let appModel = model.appModel {
                AgentWorldSurface(model: model, appModel: appModel)
                    .modifier(LocusSharedPresentations(surface: .agentWorld, updates: appModel.appUpdates))
                    .appFeatureEnvironment(from: appModel)
                    .tint(model.theme == "grand-line" ? LocusTheme.warning : appModel.accentActionColor)
            } else {
                AgentWorldSurface(model: model, appModel: nil)
            }
        }
        .environment(\.locusOceanTheme, model.theme == "grand-line")
        .transformEnvironment(\.colorScheme) { scheme in if model.theme == "grand-line" { scheme = .dark } }
        .background(model.theme == "grand-line" ? Color(nsColor: LocusTheme.oceanPalette.paper) : LocusTheme.paper)
        .sheet(item: $model.selectedTransfer) { transfer in
            AgentWorldTransferDetail(world: model, transfer: transfer)
        }
        .sheet(item: $model.newAgentDraft) { profile in
            if let appModel = model.appModel {
                AgentProfileEditor(profile: profile, isNew: true,
                    existingProfiles: appModel.agentProfiles, onSave: model.saveNewAgent)
                    .environmentObject(appModel)
                    .appFeatureEnvironment(from: appModel)
            }
        }
        .accessibilityIdentifier("agentWorld.window")
    }
}

private struct AgentWorldTransferDetail: View {
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
                Image(systemName: "arrow.right").foregroundStyle(LocusTheme.muted)
                Text(name(transfer.toAgentID))
            }.font(.locus(size: 12, weight: .medium))
            Text(transfer.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
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
        .foregroundStyle(LocusTheme.ink).background(LocusTheme.panel)
        .accessibilityIdentifier("agentWorld.transfer.details")
    }
}

private struct AgentWorldSurface: View {
    @ObservedObject var model: AgentWorldModel
    let appModel: AppModel?
    @State private var search = ""
    @State private var showsResidents = true
    @State private var showsWorld = true
    private var ocean: Bool { model.theme == "grand-line" }
    private var palette: AgentWorldPalette { .init(ocean: ocean) }
    private var quarterTitle: String { ocean ? "Captain’s Quarters" : "Agent workspace" }
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
                if showsResidents || model.graphicsError != nil { residentsPanel }
                if showsWorld || !model.conversationPresented { worldCanvas }
                if model.conversationPresented {
                    if let appModel {
                        AgentWorldWorkspacePane(world: model, model: appModel, title: quarterTitle)
                            .frame(minWidth: 450, idealWidth: 620, maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Connect to Locus", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Agent conversations are available when this world is connected to the Locus workspace."))
                    }
                }
            }
        }
        .foregroundStyle(palette.ink)
        .background(palette.paper)
        .onChange(of: model.conversationPresented) { _, presented in if !presented { showsWorld = true } }
        .onChange(of: model.activityCenterRequest) { _, _ in showsWorld = true }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: ocean ? "safari" : "folder")
                .font(.locus(size: 16, weight: .medium)).foregroundStyle(ocean ? palette.warning : palette.muted)
            Text(model.projectName).font(.locus(size: 12, weight: .semibold)).lineLimit(1)
                .truncationMode(.middle).frame(minWidth: 60, alignment: .leading)
            Spacer(minLength: 10)
            Menu {
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
            if model.conversationPresented {
                Button { showsWorld.toggle() } label: {
                    Image(systemName: showsWorld ? "arrow.up.left.and.arrow.down.right" : "globe")
                }
                .buttonStyle(AgentWorldChromeButtonStyle())
                .help(showsWorld ? "Expand \(quarterTitle)" : "Show the world beside your workspace")
                .accessibilityLabel(showsWorld ? "Expand workspace" : "Show world")
                .accessibilityIdentifier("agentWorld.toggleWorld")
            }
            Button(action: model.createAgent) { Label("New Agent", systemImage: "plus") }
                .buttonStyle(AgentWorldChromeButtonStyle())
                .disabled(!model.canCreateAgent)
                .accessibilityIdentifier("agentWorld.newAgent")
            Button(action: model.openSharedChat) { Label("Crew Chat", systemImage: "bubble.left.and.bubble.right") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: model.sharedChatPresented))
                .disabled(!model.canInteract || appModel == nil)
                .accessibilityIdentifier("agentWorld.crewChat")
            Button { showsResidents.toggle() } label: { Label("Residents", systemImage: "person.3") }
                .buttonStyle(AgentWorldChromeButtonStyle(selected: showsResidents))
                .accessibilityIdentifier("agentWorld.toggleResidents")
        }
        .font(.locus(size: 11, weight: .medium))
        .controlSize(.small).padding(.horizontal, 18).frame(height: 56)
        .background(palette.panel)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Residents").font(ocean ? .locus(size: 20, weight: .semibold, design: .serif) : .locus(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(model.residents.count)").font(.locus(size: 10, weight: .semibold)).foregroundStyle(palette.warning)
                }
                Text("\(workingCount) \(ocean ? "underway" : "working") · \(attentionCount) need you")
                    .font(.locus(size: 9)).foregroundStyle(palette.muted)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                    TextField(ocean ? "Find a captain" : "Find an agent", text: $search)
                        .textFieldStyle(.plain).accessibilityIdentifier("agentWorld.residentSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.muted) }
                            .buttonStyle(.locus(.icon)).accessibilityLabel("Clear resident search")
                    }
                }
                .font(.locus(size: 10)).padding(8).background(palette.paper, in: RoundedRectangle(cornerRadius: 8))
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
                        Text(ocean ? "No captains match your search." : "No agents match your search.")
                            .font(.locus(size: 11)).foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        ForEach(filteredResidents) { resident in residentRow(resident) }
                    }
                }.padding(10)
            }
            Rectangle().fill(palette.line).frame(height: 1)
            VStack(spacing: 5) {
                compactResidentAction("Crew Chat", icon: "bubble.left.and.bubble.right", action: model.openSharedChat)
                    .disabled(!model.canInteract || appModel == nil)
                    .accessibilityIdentifier("agentWorld.residents.crewChat")
                compactResidentAction(quarterTitle, icon: ocean ? "safari" : "rectangle.3.group") { model.openAgentControls() }
                    .disabled(!model.canInteract || model.residents.isEmpty)
                    .accessibilityIdentifier("agentWorld.residents.quarters")
                compactResidentAction(ocean ? "Den Den Dispatch" : "Activity Center", icon: ocean ? "phone.connection" : "bell", badge: attentionCount,
                                      action: model.requestActivityCenter)
                    .help("Open attention requests and the crew activity log")
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
        .frame(minWidth: 190, idealWidth: 206, maxWidth: 238)
        .background(palette.panel)
        .accessibilityIdentifier("agentWorld.residents")
    }

    private func residentRow(_ resident: AgentWorldResident) -> some View {
        let selected = model.selection == resident.id
        let placement = model.residentPlacements[resident.id]
        return VStack(spacing: 0) {
            Button { model.select(resident.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    if ocean {
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
                            Text(AgentWorldChrome.statusLabel(resident.status, ocean: ocean)).font(.locus(size: 9, weight: .medium))
                        }.foregroundStyle(AgentWorldChrome.statusColor(resident.status)).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "chevron.right").font(.locus(size: 9, weight: .semibold)).foregroundStyle(palette.warning).padding(.top, 7) }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.locus(.card))
            .help(resident.detail ?? "Open \(resident.name)’s conversation")
            .accessibilityLabel("\(resident.name), \(placement.map { "\($0.ship), \($0.home), " } ?? "")\(resident.role), \(AgentWorldChrome.statusLabel(resident.status, ocean: ocean))")
            .accessibilityIdentifier("agentWorld.resident.\(resident.id)")
            HStack(spacing: 7) {
                Button { model.newConversation(for: resident.id) } label: {
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
                    Button(ocean ? "Open Vivre card" : "Agent details") { model.openAgentProfile(resident.id) }
                    if let profile = appModel?.agentProfiles.first(where: { $0.id.uuidString == resident.id }) {
                        Button("Edit agent…") { appModel?.presentSavedAgentEditor(profile) }
                        Button("Manage agent…") { appModel?.manageSavedAgent(profile) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 16, height: 20) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!model.canInteract)
                .accessibilityLabel("Actions for \(resident.name)")
                .accessibilityIdentifier("agentWorld.residentActions.\(resident.id)")
            }
            .font(.locus(size: 9, weight: .medium)).foregroundStyle(palette.warning)
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .background(selected ? palette.white : .clear, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? palette.warning.opacity(0.5) : .clear, lineWidth: 1))
    }

    private func compactResidentAction(_ title: String, icon: String, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(palette.warning).frame(width: 16)
                Text(title).font(.locus(size: 10, weight: .medium)).lineLimit(1)
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
                    .foregroundStyle(AgentWorldPalette(ocean: true).warning)
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
        case "working": ocean ? "Underway · working" : "Working"
        case "needs_attention": "Needs you"
        case "queued": "Queued"
        case "failed": "Needs attention"
        case "completed": "Completed"
        default: ocean ? "At anchor · available" : "Available"
        }
    }
}

struct AgentWorldChromeButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.locusOceanTheme) private var ocean
    private var palette: AgentWorldPalette { .init(ocean: ocean) }
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
struct AgentWorldPalette {
    let ocean: Bool
    var ink: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.ink) : LocusTheme.ink }
    var inkSoft: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.inkSoft) : LocusTheme.inkSoft }
    var paper: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.paper) : LocusTheme.paper }
    var paperDeep: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.paperDeep) : LocusTheme.paperDeep }
    var panel: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.panel) : LocusTheme.panel }
    var white: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.white) : LocusTheme.white }
    var line: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.line) : LocusTheme.line }
    var muted: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.muted) : LocusTheme.muted }
    var warning: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.warning) : LocusTheme.warning }
    var success: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.success) : LocusTheme.success }
    var danger: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.danger) : LocusTheme.danger }
    var blue: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.blue) : LocusTheme.blue }
    var signal: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.signal) : LocusTheme.signal }
}

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
