import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [CommandAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return CommandAction.allCases }
        return CommandAction.allCases.filter {
            "\($0.title) \($0.rawValue)".lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(LocusTheme.muted)
                TextField("Run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .accessibilityIdentifier("palette.search")
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(commands.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.return) {
                        runSelected()
                        return .handled
                    }
                Button("esc") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("Close command palette")
                    .accessibilityIdentifier("palette.close")
            }
            .padding(.horizontal, 15)
            .frame(height: 53)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            if commands.isEmpty {
                Text("No commands match that search.")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(spacing: 3) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button {
                                    model.runCommand(command)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: command.symbol)
                                            .font(.system(size: 13))
                                            .foregroundStyle(LocusTheme.muted)
                                            .frame(width: 30, height: 30)
                                            .background(LocusTheme.panel)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(LocusTheme.line, lineWidth: 1)
                                            }
                                        Text(command.title)
                                            .font(.system(size: 10, weight: .medium))
                                        Spacer()
                                        if index == selection {
                                            Text("↵")
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                        if !command.shortcut.isEmpty {
                                            Text(command.shortcut)
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 44)
                                    .background(index == selection ? LocusTheme.paperDeep.opacity(0.8) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { selection = index }
                                }
                                .id(index)
                                .accessibilityIdentifier("palette.command.\(command.rawValue)")
                            }
                        }
                        .padding(7)
                        .onChange(of: selection) {
                            proxy.scrollTo(selection)
                        }
                    }
                }
            }

            HStack(spacing: 15) {
                Text("↑↓ Navigate")
                Text("↵ Select")
                Spacer()
                Text("⌘K Close")
            }
            .font(.system(size: 7))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(LocusTheme.paperDeep.opacity(0.7))
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
        }
        .frame(width: 520, height: 430)
        .background(LocusTheme.white)
        .onAppear { focused = true }
        .onChange(of: query) {
            selection = 0
        }
        .onExitCommand { dismiss() }
        .background {
            // ⌘K closes the palette, matching the footer hint and the
            // shortcut that opened it.
            Button("") { dismiss() }
                .keyboardShortcut("k", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func runSelected() {
        let available = commands
        guard !available.isEmpty else { return }
        model.runCommand(available[min(selection, available.count - 1)])
    }
}

private struct PluginInstallReview: Identifiable {
    var id: String { trust.digest }
    let entry: ExtensionCatalogEntry
    let trust: PluginTrustResponse
}

private struct ExtensionsSettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case marketplace = "Marketplace"
        case mcp = "MCP Servers"
        case skills = "Skills"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .installed
    @State private var search = ""
    @State private var marketplaceID = ""
    @State private var marketplaceSource = ""
    @State private var marketplaceName = ""
    @State private var review: PluginInstallReview?
    @State private var editorPresented = false
    @State private var editingServer: ExtensionMCPServer?
    @State private var credentialServer: ExtensionMCPServer?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Extensions", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue)
                        .tag(tab)
                        .accessibilityIdentifier("extensions.tab.\(tab.id.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            if let error = model.extensionErrorMessage, !error.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.extensionErrorMessage = nil }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.coral)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Group {
                switch tab {
                case .installed: installedPane
                case .marketplace: marketplacePane
                case .mcp: mcpPane
                case .skills: skillsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await model.refreshExtensions()
            await model.refreshExtensionCatalog()
        }
        .sheet(item: $review) { item in
            PluginTrustReviewView(item: item) { scope in
                review = nil
                Task { await model.installPlugin(item.entry, trust: item.trust, scope: scope) }
            }
        }
        .sheet(isPresented: $editorPresented) {
            MCPServerEditorView(server: editingServer)
                .environmentObject(model)
        }
        .sheet(item: $credentialServer) { server in
            MCPCredentialView(server: server)
                .environmentObject(model)
        }
    }

    private var installedPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.extensions.plugins.isEmpty {
                    ContentUnavailableView(
                        "No plugins installed",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Choose a source in Marketplace, then review and install a plugin.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 330)
                }
                ForEach(model.extensions.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.displayName ?? plugin.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text([
                                    plugin.version.map { "Version \($0)" },
                                    plugin.author,
                                ].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                                if plugin.updateAvailable == true {
                                    Text("Update available")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(LocusTheme.warning)
                                }
                            }
                            Spacer()
                            Button(plugin.enabledGlobal ? "Disable everywhere" : "Enable everywhere") {
                                Task { await model.setPlugin(plugin.id, enabled: !plugin.enabledGlobal, scope: "global") }
                            }
                            .disabled(model.isBusy)
                        }
                        if let description = plugin.description, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 10))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        HStack(spacing: 12) {
                            Label("\(plugin.skills?.count ?? 0) skills", systemImage: "sparkles")
                            Label("\(plugin.mcpServers?.count ?? 0) MCP servers", systemImage: "externaldrive.connected.to.line.below")
                            if !(plugin.unsupported ?? []).isEmpty {
                                Label("Unsupported items", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(LocusTheme.warning)
                            }
                            Spacer()
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        HStack {
                            let workspaceEnabled = !plugin.disabledWorkspaces.contains(model.workspacePath)
                                && (plugin.enabledGlobal || plugin.enabledWorkspaces.contains(model.workspacePath))
                            Button(workspaceEnabled ? "Disable for this workspace" : "Enable for this workspace") {
                                Task { await model.setPlugin(plugin.id, enabled: !workspaceEnabled, scope: "workspace") }
                            }
                            .disabled(model.isBusy)
                            if !(plugin.previousVersions ?? []).isEmpty {
                                Button("Roll back") { Task { await model.rollbackPlugin(plugin.id) } }
                                    .disabled(model.isBusy)
                            }
                            if plugin.updateAvailable == true {
                                Button("Review update") {
                                    Task {
                                        if let (entry, trust) = await model.inspectUpdate(for: plugin) {
                                            review = PluginInstallReview(entry: entry, trust: trust)
                                        }
                                    }
                                }
                                .disabled(model.isBusy)
                            }
                            Spacer()
                            Button("Uninstall", role: .destructive) {
                                Task { await model.uninstallPlugin(plugin.id) }
                            }
                            .disabled(model.isBusy)
                        }
                        .font(.system(size: 9))
                    }
                    .padding(12)
                    .locusCard(radius: 10)
                }
            }
            .padding(14)
        }
    }

    private var marketplacePane: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Source", selection: $marketplaceID) {
                    Text("All sources").tag("")
                    ForEach(model.extensions.marketplaces) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .frame(maxWidth: 230)
                TextField("Search plugins", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await model.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
                    }
                Button("Search") {
                    Task { await model.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
                }
            }
            HStack {
                TextField("Local folder, owner/repo, or HTTPS Git URL", text: $marketplaceSource)
                    .textFieldStyle(.roundedBorder)
                TextField("Name (optional)", text: $marketplaceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button("Add source") {
                    let source = marketplaceSource
                    marketplaceSource = ""
                    Task { await model.addMarketplace(source: source, name: marketplaceName) }
                }
                .disabled(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 9))

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(model.extensionCatalog) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "shippingbox")
                                .frame(width: 22, height: 22)
                                .foregroundStyle(LocusTheme.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.displayName ?? entry.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(entry.description?.isEmpty == false ? entry.description! : (entry.category ?? "Plugin"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(2)
                                if let error = entry.error {
                                    Text(error).font(.system(size: 8)).foregroundStyle(LocusTheme.coral)
                                }
                            }
                            Spacer()
                            Button(entry.installed ? "Review update" : "Review & install") {
                                Task {
                                    if let trust = await model.inspectPlugin(entry) {
                                        review = PluginInstallReview(entry: entry, trust: trust)
                                    }
                                }
                            }
                            .disabled(!entry.available || model.isBusy)
                        }
                        .padding(11)
                        .locusCard(radius: 9)
                    }
                    if model.extensionCatalog.isEmpty {
                        ContentUnavailableView(
                            "No plugins found",
                            systemImage: "magnifyingglass",
                            description: Text("Add or refresh a marketplace source, then search again.")
                        )
                        .frame(minHeight: 260)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 14)
        .onChange(of: marketplaceID) {
            Task { await model.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
        }
    }

    private var mcpPane: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("External tools from MCP servers")
                        .font(.system(size: 11, weight: .semibold))
                    if !model.extensions.capabilities.stdio {
                        Text("This App Store build supports remote MCP servers and skills. Local command-based servers are unavailable.")
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                Spacer()
                Button("Add server") {
                    editingServer = nil
                    editorPresented = true
                }
                .disabled(model.isBusy)
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(model.extensions.mcpServers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(mcpStatusColor(server.state))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).font(.system(size: 11, weight: .semibold))
                                    Text("\(server.transport.uppercased()) · \(server.state ?? "disconnected") · \(server.toolCount ?? 0) tools")
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                Button("Test") { Task { await model.testMCPServer(server.id) } }
                                    .disabled(model.isBusy)
                                Button("Reconnect") { Task { await model.reconnectMCPServer(server.id) } }
                                    .disabled(model.isBusy)
                                if server.origin == "user" {
                                    Button("Edit") {
                                        editingServer = server
                                        editorPresented = true
                                    }
                                }
                            }
                            if let error = server.error, !error.isEmpty {
                                Text(error).font(.system(size: 8)).foregroundStyle(LocusTheme.coral)
                            }
                            HStack {
                                Menu("Default: \(policyTitle(server.approvalMode))") {
                                    policyButtons(serverID: server.id, tool: nil)
                                }
                                if server.auth == "oauth" {
                                    Button(server.hasCredentials == true ? "Reconnect account" : "Connect account") {
                                        model.authenticateMCPServer(server)
                                    }
                                } else if server.auth != "none" {
                                    Button(server.hasCredentials == true ? "Update credentials" : "Add credentials") {
                                        credentialServer = server
                                    }
                                }
                                if server.hasCredentials == true {
                                    Button("Forget credentials") {
                                        Task { await model.clearMCPCredentials(serverID: server.id) }
                                    }
                                }
                                Spacer()
                                let workspaceEnabled = server.disabledWorkspaces?.contains(model.workspacePath) != true
                                    && (server.enabledGlobal == true || server.enabledWorkspaces?.contains(model.workspacePath) == true)
                                if let pluginID = server.pluginID {
                                    Button(workspaceEnabled ? "Disable plugin here" : "Enable plugin here") {
                                        Task { await model.setPlugin(pluginID, enabled: !workspaceEnabled, scope: "workspace") }
                                    }
                                } else {
                                    Button(workspaceEnabled ? "Disable here" : "Enable here") {
                                        Task { await model.setMCPServer(server.id, enabled: !workspaceEnabled, scope: "workspace") }
                                    }
                                }
                                if server.origin == "user" {
                                    Button("Remove", role: .destructive) {
                                        Task { await model.removeMCPServer(server.id) }
                                    }
                                }
                            }
                            .font(.system(size: 9))

                            let tools = model.extensionTools.filter { $0.serverID == server.id }
                            if !tools.isEmpty {
                                DisclosureGroup("Tool permissions") {
                                    ForEach(tools) { tool in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(tool.name).font(.system(size: 9, weight: .medium, design: .monospaced))
                                                Text(tool.description).font(.system(size: 8)).foregroundStyle(LocusTheme.muted).lineLimit(1)
                                            }
                                            Spacer()
                                            Menu(policyTitle(tool.approvalMode)) {
                                                policyButtons(serverID: server.id, tool: tool.name)
                                            }
                                        }
                                    }
                                }
                                .font(.system(size: 9))
                            }
                        }
                        .padding(11)
                        .locusCard(radius: 9)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var skillsPane: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reusable workflows").font(.system(size: 11, weight: .semibold))
                    Text("Type $skill in the composer. Locus can also load skills automatically when their metadata matches your request.")
                        .font(.system(size: 9)).foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Import skill…") { chooseSkill() }.disabled(model.isBusy)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.extensions.skills) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles").foregroundStyle(LocusTheme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("$\(skill.id)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text(skill.description).font(.system(size: 9)).foregroundStyle(LocusTheme.muted).lineLimit(2)
                                Text("\(skill.source) · \(skill.allowImplicitInvocation == false ? "explicit only" : "automatic or explicit")")
                                    .font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
                            }
                            Spacer()
                            if skill.source == "imported" {
                                Button(skill.enabled ? "Disable" : "Enable") {
                                    Task { await model.setSkill(skill.id, enabled: !skill.enabled, scope: "global") }
                                }
                                Button("Remove", role: .destructive) {
                                    Task { await model.removeSkill(skill.id) }
                                }
                            } else {
                                Text(skill.enabled ? "Enabled" : "Managed by plugin")
                                    .font(.system(size: 8)).foregroundStyle(LocusTheme.muted)
                            }
                        }
                        .padding(10)
                        .locusCard(radius: 9)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func policyButtons(serverID: String, tool: String?) -> some View {
        Button("Use annotations") { Task { await model.setMCPPolicy(serverID: serverID, tool: tool, mode: "annotations") } }
        Button("Ask") { Task { await model.setMCPPolicy(serverID: serverID, tool: tool, mode: "ask") } }
        Button("Allow") { Task { await model.setMCPPolicy(serverID: serverID, tool: tool, mode: "allow") } }
        Button("Disabled") { Task { await model.setMCPPolicy(serverID: serverID, tool: tool, mode: "disabled") } }
    }

    private func policyTitle(_ value: String?) -> String {
        switch value {
        case "allow": "Allow"
        case "ask", "prompt": "Ask"
        case "disabled": "Disabled"
        default: "Use annotations"
        }
    }

    private func mcpStatusColor(_ state: String?) -> Color {
        switch state {
        case "connected": LocusTheme.success
        case "connecting": LocusTheme.warning
        default: LocusTheme.coral
        }
    }

    private func chooseSkill() {
        let panel = NSOpenPanel()
        panel.title = "Choose a skill folder or SKILL.md"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importSkill(from: url.path) }
        }
    }
}

private struct PluginTrustReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let item: PluginInstallReview
    let install: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.entry.installed ? "Review plugin update" : "Review plugin")
                .font(.system(size: 16, weight: .bold))
            Text(item.trust.plugin.displayName ?? item.trust.plugin.name)
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Publisher"); Text(item.trust.plugin.author ?? "Not provided") }
                GridRow {
                    Text("Source")
                    Text(
                        item.trust.source?["url"]
                            ?? item.trust.source?["path"]
                            ?? item.entry.marketplaceID
                    )
                }
                GridRow { Text("Version"); Text(item.trust.plugin.version ?? "Not provided") }
                GridRow { Text("Digest"); Text(String(item.trust.digest.prefix(20)) + "…").fontDesign(.monospaced) }
                GridRow { Text("Skills"); Text("\(item.trust.trust.skills)") }
            }
            .font(.system(size: 9))
            if !item.trust.trust.skillScripts.isEmpty {
                trustWarning("Skill scripts", item.trust.trust.skillScripts)
            }
            if let diff = item.trust.capabilityDiff, !diff.changes.isEmpty {
                trustWarning("Capability changes", diff.changes)
            }
            ForEach(item.trust.trust.mcpServers, id: \.name) { server in
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP: \(server.name)").font(.system(size: 10, weight: .semibold))
                    Text(
                        server.transport == "stdio"
                            ? ([server.command].compactMap { $0 } + (server.args ?? [])).joined(separator: " ")
                            : (server.url ?? "Remote endpoint")
                    )
                    if let cwd = server.cwd, !cwd.isEmpty { Text("Working directory: \(cwd)") }
                    if !server.requestedEnv.isEmpty { Text("Environment access: \(server.requestedEnv.joined(separator: ", "))") }
                    if !server.requestedHeaders.isEmpty { Text("Headers: \(server.requestedHeaders.joined(separator: ", "))") }
                }
                .font(.system(size: 9))
                .padding(8)
                .locusCard(radius: 7)
            }
            if !item.trust.trust.unsupported.isEmpty {
                trustWarning("Not supported by Locus V1", item.trust.trust.unsupported)
            }
            Text("Install only if you trust this publisher and source. Capability changes will require another review.")
                .font(.system(size: 9)).foregroundStyle(LocusTheme.muted)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Install for this workspace") { install("workspace") }
                Button("Install everywhere") { install("global") }
                    .buttonStyle(.borderedProminent).tint(LocusTheme.ink)
            }
        }
        .padding(18)
        .frame(width: 520, height: 520)
        .background(LocusTheme.panel)
    }

    private func trustWarning(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold))
            ForEach(values, id: \.self) { Text("• \($0)").font(.system(size: 9)) }
        }
        .foregroundStyle(LocusTheme.warning)
    }
}

private struct MCPServerEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: ExtensionMCPServer?
    @State private var name = ""
    // Must match the agent's own spelling (extensions.py writes "streamable_http");
    // the hyphenated form matched neither Picker tag nor the saved value, so the
    // control rendered blank when editing a correctly configured server.
    @State private var transport = "streamable_http"
    @State private var url = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var auth = "none"
    @State private var approval = "annotations"
    @State private var authorizationEndpoint = ""
    @State private var tokenEndpoint = ""
    @State private var clientID = ""
    @State private var scopes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add MCP server" : "Edit MCP server")
                .font(.system(size: 16, weight: .bold))
            Form {
                TextField("Name", text: $name)
                Picker("Transport", selection: $transport) {
                    Text("Remote (Streamable HTTP)").tag("streamable_http")
                    Text("Local command (stdio)").tag("stdio")
                }
                if transport == "stdio" {
                    TextField("Command", text: $command)
                    TextEditor(text: $arguments)
                        .frame(height: 55)
                        .overlay(alignment: .topLeading) {
                            if arguments.isEmpty { Text("One argument per line").foregroundStyle(LocusTheme.muted).padding(5) }
                        }
                    if !model.extensions.capabilities.stdio {
                        Text("Local command servers are unavailable in this App Store build.")
                            .foregroundStyle(LocusTheme.coral)
                    }
                } else {
                    TextField("Server URL", text: $url)
                }
                Picker("Authentication", selection: $auth) {
                    Text("None").tag("none")
                    Text("Bearer token").tag("bearer")
                    Text("Custom header").tag("headers")
                    Text("OAuth 2.0 (PKCE)").tag("oauth")
                }
                if auth == "oauth" {
                    TextField("Authorization endpoint", text: $authorizationEndpoint)
                    TextField("Token endpoint", text: $tokenEndpoint)
                    TextField("Client ID", text: $clientID)
                    TextField("Scopes, separated by spaces", text: $scopes)
                }
                Picker("Default tool policy", selection: $approval) {
                    Text("Use safety annotations").tag("annotations")
                    Text("Ask").tag("ask")
                    Text("Allow").tag("allow")
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    var body: [String: Any] = [
                        "name": name,
                        "transport": transport,
                        "url": url,
                        "command": command,
                        "args": arguments.components(separatedBy: .newlines).filter { !$0.isEmpty },
                        "auth": auth,
                        "default_tools_approval_mode": approval,
                    ]
                    if let server { body["id"] = server.id }
                    if auth == "oauth" {
                        body["oauth"] = [
                            "authorization_endpoint": authorizationEndpoint,
                            "token_endpoint": tokenEndpoint,
                            "client_id": clientID,
                            "scopes": scopes.split(separator: " ").map(String.init),
                            "redirect_uri": "locus://mcp/oauth",
                        ]
                    }
                    Task { await model.saveMCPServer(body) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(name.isEmpty || (transport == "stdio" ? command.isEmpty : url.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 500, height: 540)
        .background(LocusTheme.panel)
        .onAppear {
            guard let server else { return }
            name = server.name
            transport = server.transport
            url = server.url ?? ""
            command = server.command ?? ""
            arguments = (server.args ?? []).joined(separator: "\n")
            auth = server.auth ?? "none"
            approval = server.approvalMode ?? "annotations"
            authorizationEndpoint = server.oauth?.authorizationEndpoint ?? ""
            tokenEndpoint = server.oauth?.tokenEndpoint ?? ""
            clientID = server.oauth?.clientID ?? ""
            scopes = (server.oauth?.scopes ?? []).joined(separator: " ")
        }
    }
}

private struct MCPCredentialView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: ExtensionMCPServer
    @State private var secret = ""
    @State private var fieldName = "Authorization"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials for \(server.name)").font(.system(size: 15, weight: .bold))
            if server.auth == "headers" || server.transport == "stdio" {
                TextField(server.transport == "stdio" ? "Environment variable" : "Header name", text: $fieldName)
            }
            SecureField(server.auth == "bearer" ? "Bearer token" : "Secret value", text: $secret)
            Text("The value is written to \(CredentialStore.displayPath), readable only by your macOS user account, and sent to the local agent only in memory.")
                .font(.system(size: 9)).foregroundStyle(LocusTheme.muted)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    let values: [String: Any]
                    if server.auth == "bearer" {
                        values = ["access_token": secret]
                    } else if server.transport == "stdio" {
                        values = ["env": [fieldName: secret]]
                    } else {
                        values = ["headers": [fieldName: secret]]
                    }
                    Task { await model.setMCPCredentials(serverID: server.id, values: values) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(LocusTheme.ink)
                .disabled(secret.isEmpty || fieldName.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420, height: 210)
        .background(LocusTheme.panel)
    }
}

struct CheckpointSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session checkpoints")
                        .font(.system(size: 15, weight: .bold))
                    Text("Save and restore the conversation, tasks, workspace, model, and context pack.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close checkpoints")
                .accessibilityIdentifier("checkpoints.close")
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("Checkpoint name (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("checkpoints.title")
                Button("Create Checkpoint") {
                    model.createCheckpoint(title: title)
                    title = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .accessibilityIdentifier("checkpoints.create")
            }
            .padding(14)

            if model.checkpoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 25))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No checkpoints yet")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Create one before a risky or exploratory turn.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.checkpoints) { checkpoint in
                            HStack(spacing: 11) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LocusTheme.signal)
                                    .frame(width: 34, height: 34)
                                    .background(LocusTheme.ink)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(checkpoint.title)
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                Button("Restore") {
                                    model.restore(checkpoint)
                                }
                                .accessibilityIdentifier("checkpoints.restore.\(checkpoint.id)")
                                Button {
                                    model.delete(checkpoint)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(LocusTheme.coral)
                                .help("Delete checkpoint")
                                .accessibilityLabel("Delete \(checkpoint.title)")
                            }
                            .padding(10)
                            .locusCard(radius: 9)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(width: 560, height: 500)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings()
    @State private var localWindow = ""
    @State private var addingAccount: ProviderAccount?
    @State private var editingAccount: ProviderAccount?
    @State private var accountPendingRemoval: ProviderAccount?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Locus Settings")
                        .font(.system(size: 16, weight: .bold))
                    Text("Local agent and preview configuration")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                    model.settingsPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
                .accessibilityIdentifier("settings.close")
            }
            .padding(17)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            HStack(spacing: 0) {
                List(SettingsPage.allCases, selection: $model.settingsPage) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .tag(item)
                        .accessibilityIdentifier("settings.page.\(item.id.lowercased())")
                }
                .listStyle(.sidebar)
                .frame(width: 155)

                Rectangle().fill(LocusTheme.line).frame(width: 1)

                if model.settingsPage == .general {
                    Form {
                Section("Model providers") {
                    Label(
                        "Local Ollama — models installed on this Mac appear in the picker automatically.",
                        systemImage: "bolt.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)

                    TextField("Local context window in tokens (optional)", text: $localWindow)
                        .accessibilityIdentifier("settings.localContextWindow")

                    Text("Leave empty to use the window Ollama is really running the model in, measured once it is loaded. Set a value to pin one — it is requested as num_ctx and is what compaction budgets against.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.providerAccounts) { account in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(
                                    model.accountStatus[account.id]?.isHealthy ?? account.hasKey
                                        ? LocusTheme.success
                                        : LocusTheme.coral
                                )
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(accountDetail(account))
                                    .font(.system(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Edit") { editingAccount = account }
                                .accessibilityIdentifier("settings.accounts.edit")
                            Button("Remove") { accountPendingRemoval = account }
                                .accessibilityIdentifier("settings.accounts.remove")
                        }
                        .accessibilityIdentifier("settings.accounts.row")
                    }

                    Menu("Add Account…") {
                        ForEach(ProviderKind.allCases) { kind in
                            Button(kind.title) {
                                addingAccount = ProviderAccount(kind: kind)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.accounts.add")

                    Text("Each account keeps its API key in \(CredentialStore.displayPath), a file readable only by your macOS user account. Keys are passed to the local agent in memory and only ever sent to their own provider. Any program running as you can read that file.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Permissions") {
                    Picker("The agent may", selection: Binding(
                        get: { model.permissionMode },
                        set: { model.setPermissionMode($0) }
                    )) {
                        ForEach(PermissionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings.permissionMode")

                    Text(model.permissionMode.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(
                            model.permissionMode.isRisky ? LocusTheme.coral : LocusTheme.muted
                        )
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.allowedTools.isEmpty {
                        LabeledContent("Always allowed") {
                            Text(model.allowedTools.joined(separator: ", "))
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }

                    Button("Reset session allowances") { model.resetPermissions() }
                        .disabled(model.allowedTools.isEmpty && model.permissionMode == .ask)
                        .accessibilityIdentifier("settings.resetPermissions")

                    Text("Reading, searching and listing inside the workspace never ask. Anything outside it always does, in every mode.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Local agent") {
                    Text("The app includes its own local-agent runtime. These settings are used for custom or development backends.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                    TextField("Backend URL", text: $draft.backendURL)
                        .accessibilityIdentifier("settings.backendURL")
                    TextField("Fallback backend folder", text: $draft.backendRoot)
                        .accessibilityIdentifier("settings.backendRoot")
                    HStack {
                        Button("Choose Folder…") { chooseBackendFolder() }
                            .accessibilityIdentifier("settings.chooseBackend")
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: draft.backendRoot))
                        }
                        .accessibilityIdentifier("settings.revealBackend")
                    }
                }

                Section("Preview") {
                    TextField("Preview URL", text: $draft.previewURL)
                        .accessibilityIdentifier("settings.previewURL")
                }

                Section("Notifications") {
                    Toggle(
                        "Notify when a run finishes while Locus is in the background",
                        isOn: $draft.notifyOnCompletion
                    )
                    .accessibilityIdentifier("settings.notifyOnCompletion")
                }

                Section("Status") {
                    LabeledContent("Agent") {
                        Text(runtimeLabel(model.agentRuntimePhase))
                            .foregroundStyle(runtimeColor(model.agentRuntimePhase))
                            .accessibilityIdentifier("settings.agentStatus")
                            .accessibilityLabel(runtimeLabel(model.agentRuntimePhase))
                    }
                    LabeledContent(model.activeAccount?.displayName ?? "Ollama") {
                        Text(runtimeLabel(model.modelRuntimePhase))
                            .foregroundStyle(runtimeColor(model.modelRuntimePhase))
                            .accessibilityIdentifier("settings.modelStatus")
                            .accessibilityLabel(runtimeLabel(model.modelRuntimePhase))
                    }
                    if let reason = model.modelRuntimePhase.message, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(runtimeColor(model.modelRuntimePhase))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.ollamaError")
                    }
                    if !model.backendLogHint.isEmpty {
                        Text(model.backendLogHint)
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    if !model.isAgentOnline || !model.isModelOnline {
                        Button("Retry Now") { model.retryLocalServices() }
                            .accessibilityIdentifier("settings.retryLocalServices")
                    }
                }
                    }
                    .formStyle(.grouped)
                } else {
                    ExtensionsSettingsView()
                        .environmentObject(model)
                }
            }

            if model.settingsPage == .general {
                HStack {
                    Button("Cancel") {
                        dismiss()
                        model.settingsPresented = false
                    }
                    .accessibilityIdentifier("settings.cancel")
                    Spacer()
                    Button("Save") {
                        var saved = draft
                        let typed = localWindow.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.localContextWindow = typed.isEmpty ? nil : Int(typed)
                        model.applySettings(saved)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .accessibilityIdentifier("settings.save")
                }
                .padding(15)
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
                }
            }
        }
        .frame(width: 780, height: 620)
        .background(LocusTheme.panel)
        .onAppear { draft = model.settings }
        .onExitCommand {
            dismiss()
            model.settingsPresented = false
        }
        // Accounts are saved as they are edited rather than with the rest of
        // the draft: they write the credential file, and Cancel cannot un-write it.
        .sheet(item: $addingAccount) { account in
            AccountEditorView(account: account, isNew: true)
                .environmentObject(model)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: false)
                .environmentObject(model)
        }
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text("Remove \(account.displayName)?"),
                message: Text(
                    account.id.uuidString == model.settings.activeAccountID
                        ? "The API key is deleted from \(CredentialStore.displayPath) and Locus switches back to local Ollama. Saved transcripts are kept."
                        : "The API key is deleted from \(CredentialStore.displayPath). Saved transcripts are kept."
                ),
                primaryButton: .destructive(Text("Remove")) {
                    model.removeProviderAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func accountDetail(_ account: ProviderAccount) -> String {
        let status = model.accountStatus[account.id]
            ?? (account.hasKey ? .keySaved : .noKey)
        let host = URL(string: RemoteEndpointTester.normalizeBaseURL(account.resolvedBaseURL))?.host
        return [host, status.summary].compactMap { $0 }.joined(separator: " · ")
    }

    private func runtimeLabel(_ phase: RuntimePhase) -> String {
        switch phase {
        case .starting: "Starting"
        case .online: "Online"
        case .recovering: "Recovering"
        case .unavailable: "Unavailable"
        }
    }

    private func runtimeColor(_ phase: RuntimePhase) -> Color {
        switch phase {
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
        }
    }

    private func chooseBackendFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the ollama-code backend folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.backendRoot)
        if panel.runModal() == .OK, let url = panel.url {
            draft.backendRoot = url.path
        }
    }
}
