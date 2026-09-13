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
    @State private var search = ""
    @State private var showsResidents = false
    private var filteredResidents: [AgentWorldResident] {
        model.residents.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.role.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.projectName).font(.caption.weight(.semibold))
                Spacer()
                Button { showsResidents.toggle() } label: { Label("Residents", systemImage: "person.3") }
                    .controlSize(.small)
                    .accessibilityIdentifier("agentWorld.toggleResidents")
            }.padding(.horizontal, 14).frame(height: 38)
            Divider()
            HSplitView {
            if showsResidents || model.graphicsError != nil {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sparkles.rectangle.stack")
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
                        }.buttonStyle(.locus())
                            .listRowBackground(model.selection == resident.id ? Color.accentColor.opacity(0.12) : .clear)
                            .accessibilityIdentifier("agentWorld.resident.\(resident.id)")
                    }.listStyle(.sidebar)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.projectName).font(.caption.weight(.semibold))
                    Text("This window stays with this project.").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
            }
            ZStack {
                Color(red: 0.025, green: 0.04, blue: 0.07)
                if let screen = model.activeScreen { PluginScreenHost(model: model, screen: screen).id(screen.id + (screen.digest ?? "")) }
                if let error = model.graphicsError {
                    VStack(spacing: 10) {
                        Image(systemName: "map").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).frame(maxWidth: 340)
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("agentWorld.world")
            if model.selectedProfile != nil {
                conversationPanel.frame(minWidth: 300, idealWidth: 350, maxWidth: 500)
            }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("agentWorld.window")
    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let profile = model.selectedProfile {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.name).font(.title3.weight(.semibold))
                        Spacer()
                        Button(action: model.dismissConversation) { Image(systemName: "xmark") }
                            .buttonStyle(.locus(.icon)).help("Return to the world")
                            .accessibilityIdentifier("agentWorld.closeConversation")
                        Menu {
                            Button("Start a new conversation", action: model.newConversation).disabled(model.conversationBusy)
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    Text("\(profile.role.rawValue.capitalized) · \(profile.model)").font(.caption).foregroundStyle(.secondary)
                    if let detail = model.residents.first(where: { $0.id == profile.id.uuidString })?.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open in Locus", action: model.openSelectedInLocus)
                            .accessibilityIdentifier("agentWorld.openInLocus")
                        if model.conversationBusy {
                            Button("Stop", role: .destructive, action: model.stopSelected)
                        }
                    }.controlSize(.small)
                }.padding(16)
                Divider()
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if model.blocks.isEmpty {
                                Text("Talk with \(profile.name), or assign work in \(model.projectName).").font(.callout).foregroundStyle(.secondary).padding(.vertical, 15)
                            }
                            ForEach(model.blocks.filter { [.user, .assistant, .error, .note].contains($0.kind) }) { block in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(block.kind == .user ? "You" : profile.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(block.text).font(.locus(size: 13)).textSelection(.enabled)
                                        .foregroundStyle(block.kind == .error ? Color.red : .primary)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(block.id)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(16)
                    }.onChange(of: model.blocks) { _, _ in reader.scrollTo("end", anchor: .bottom) }
                }
                if model.conversationBusy {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(model.residents.first(where: { $0.id == profile.id.uuidString })?.status == "needs_attention"
                             ? "Needs your attention — open in Locus" : "Working…")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if model.pendingCount > 0 { Text("\(model.pendingCount) message\(model.pendingCount == 1 ? "" : "s") queued").font(.caption).padding(.horizontal, 16).padding(.bottom, 8) }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8) }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Message \(profile.name)…", text: $model.draft, axis: .vertical)
                        .lineLimit(3...7).textFieldStyle(.plain)
                        .accessibilityIdentifier("agentWorld.composer")
                    HStack {
                        Button("Chat") { model.submit(mode: .ask) }
                            .help("Talk without tools or workspace access")
                            .accessibilityIdentifier("agentWorld.chat")
                        Button("Assign work") { model.submit(mode: .work) }
                            .buttonStyle(.borderedProminent)
                            .help("Use this agent's configured tools and permissions")
                            .accessibilityIdentifier("agentWorld.assignWork")
                    }.disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.selectedSessionID == nil || !model.canInteract)
                    Text("Approvals and detailed task controls open in Locus.").font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                ContentUnavailableView("Meet an agent", systemImage: "bubble.left.and.bubble.right", description: Text("Click an agent or choose one from the Residents list to start a conversation."))
            }
        }
    }
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "working": .cyan
        case "needs_attention", "queued": .orange
        case "failed": .red
        case "completed": .green
        default: .gray
        }
    }
}
