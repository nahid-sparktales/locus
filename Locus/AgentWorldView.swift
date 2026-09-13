import SwiftUI

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
                    .tint(appModel.accentActionColor)
            } else {
                AgentWorldSurface(model: model, appModel: nil)
            }
        }
        .background(LocusTheme.paper)
        .sheet(item: $model.selectedTransfer) { transfer in
            AgentWorldTransferDetail(world: model, transfer: transfer)
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
    @State private var showsResidents = false
    @State private var showsWorld = true
    private var quarterTitle: String { model.theme == "grand-line" ? "Captain’s Quarters" : "Agent workspace" }
    private var filteredResidents: [AgentWorldResident] {
        model.residents.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.role.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(model.projectName, systemImage: "folder")
                    .font(.locus(size: 11, weight: .semibold)).lineLimit(1)
                Spacer()
                if model.conversationPresented {
                    Button { showsWorld.toggle() } label: {
                        Label(showsWorld ? "Expand workspace" : "Show world", systemImage: showsWorld ? "arrow.up.left.and.arrow.down.right" : "globe")
                    }
                    .help(showsWorld ? "Give the native workspace the full window" : "Show the world beside your workspace")
                    .accessibilityIdentifier("agentWorld.toggleWorld")
                }
                Button(action: model.openSharedChat) { Label("Crew Chat", systemImage: "bubble.left.and.bubble.right") }
                    .disabled(!model.canInteract || appModel == nil)
                    .accessibilityIdentifier("agentWorld.crewChat")
                Button { showsResidents.toggle() } label: { Label("Residents", systemImage: "person.3") }
                    .accessibilityIdentifier("agentWorld.toggleResidents")
            }
            .controlSize(.small).padding(.horizontal, 14).frame(height: 42)
            .background(LocusTheme.panel)
            Divider()
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
        .onChange(of: model.conversationPresented) { _, presented in if !presented { showsWorld = true } }
    }

    private var worldCanvas: some View {
        ZStack {
            LocusTheme.paper
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
            HStack {
                Image(systemName: "person.3")
                Text("Residents").font(.headline)
                Spacer()
                Text("\(model.residents.count)").foregroundStyle(.secondary)
            }.padding(16)
            TextField("Find an agent", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            if model.residents.isEmpty {
                ContentUnavailableView("No saved agents", systemImage: "person.crop.square.badge.plus", description: Text("Create agent profiles to meet them here."))
                Button("Manage agents", action: model.manageAgents).padding()
            } else {
                List(filteredResidents) { resident in
                    Button { model.select(resident.id) } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(statusColor(resident.status)).frame(width: 7, height: 7).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(resident.name).font(.locus(size: 12, weight: .semibold)).foregroundStyle(.primary)
                                Text(resident.role.capitalized).font(.caption).foregroundStyle(.secondary)
                                Text(resident.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .listRowBackground(model.selection == resident.id ? LocusTheme.signal.opacity(0.12) : .clear)
                    .accessibilityIdentifier("agentWorld.resident.\(resident.id)")
                }.listStyle(.sidebar)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.projectName).font(.caption.weight(.semibold))
                Text("This window stays with this project.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "working": LocusTheme.signal
        case "needs_attention", "queued": LocusTheme.warning
        case "failed": LocusTheme.coral
        case "completed": LocusTheme.success
        default: LocusTheme.muted
        }
    }
}
