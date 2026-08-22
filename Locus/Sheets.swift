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
                    .font(.locus(size: 16))
                    .foregroundStyle(LocusTheme.muted)
                TextField("Run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.locus(size: 13))
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
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, design: .monospaced))
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
                    .font(.locus(size: 10))
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
                                            .font(.locus(size: 13))
                                            .foregroundStyle(LocusTheme.muted)
                                            .frame(width: 30, height: 30)
                                            .background(LocusTheme.panel)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(LocusTheme.line, lineWidth: 1)
                                            }
                                        Text(command.title)
                                            .font(.locus(size: 10, weight: .medium))
                                        Spacer()
                                        if index == selection {
                                            Text("↵")
                                                .font(.locus(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                        if !command.shortcut.isEmpty {
                                            Text(command.shortcut)
                                                .font(.locus(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 44)
                                    .background(index == selection ? LocusTheme.paperDeep.opacity(0.8) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.locus())
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
            .font(.locus(size: 7))
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
                .buttonStyle(.locus())
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
    @State private var presetReview: ExtensionMCPPreset?
    @State private var enableAfterProbe: ExtensionMCPServer?

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
                        .buttonStyle(.locus())
                }
                .font(.locus(size: 9))
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
        .sheet(item: $presetReview) { preset in
            MCPPresetReviewView(preset: preset) { projectRef in
                presetReview = nil
                connectPreset(preset, projectRef: projectRef)
            }
        }
        .sheet(item: $enableAfterProbe) { server in
            MCPEnableReviewView(server: server) { scope in
                enableAfterProbe = nil
                Task { await model.setMCPServer(server.id, enabled: true, scope: scope) }
            }
        }
        .sheet(item: $model.mcpDeviceAuthorization) { prompt in
            MCPDeviceAuthorizationView(prompt: prompt)
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
                                    .font(.locus(size: 12, weight: .semibold))
                                Text([
                                    plugin.version.map { "Version \($0)" },
                                    plugin.author,
                                ].compactMap { $0 }.joined(separator: " · "))
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                                if plugin.updateAvailable == true {
                                    Text("Update available")
                                        .font(.locus(size: 8, weight: .semibold))
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
                                .font(.locus(size: 10))
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
                        .font(.locus(size: 9))
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
                        .font(.locus(size: 9))
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
            .font(.locus(size: 9))

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(model.extensionCatalog) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "shippingbox")
                                .frame(width: 22, height: 22)
                                .foregroundStyle(LocusTheme.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.displayName ?? entry.name)
                                    .font(.locus(size: 11, weight: .semibold))
                                Text(entry.description?.isEmpty == false ? entry.description! : (entry.category ?? "Plugin"))
                                    .font(.locus(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(2)
                                if let error = entry.error {
                                    Text(error).font(.locus(size: 8)).foregroundStyle(LocusTheme.coral)
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
                        .font(.locus(size: 11, weight: .semibold))
                    if !model.extensions.capabilities.stdio {
                        Text("This App Store build supports remote MCP servers and skills. Local command-based servers are unavailable.")
                            .font(.locus(size: 9))
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
                    if !model.extensions.mcpPresets.isEmpty {
                        HStack {
                            Text("Recommended")
                                .font(.locus(size: 11, weight: .semibold))
                            Spacer()
                            Text("Bundled templates · no startup network access")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        ForEach(model.extensions.mcpPresets) { preset in
                            HStack(alignment: .top, spacing: 10) {
                                MCPLogo(
                                    name: preset.displayName,
                                    url: preset.url,
                                    presetID: preset.id,
                                    size: 28
                                )
                                .accessibilityIdentifier("extensions.mcp.preset.\(preset.id).logo")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.displayName)
                                        .font(.locus(size: 10, weight: .semibold))
                                    Text(preset.description)
                                        .font(.locus(size: 9))
                                        .foregroundStyle(LocusTheme.muted)
                                        .lineLimit(2)
                                    Text(preset.url)
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if preset.installed {
                                    Label("Added", systemImage: "checkmark.circle.fill")
                                        .font(.locus(size: 9))
                                        .foregroundStyle(LocusTheme.success)
                                } else {
                                    Button("Review & connect") { presetReview = preset }
                                        .disabled(model.isBusy)
                                }
                            }
                            .padding(10)
                            .locusCard(radius: 9)
                        }
                        Divider().padding(.vertical, 4)
                        HStack {
                            Text("Configured servers")
                                .font(.locus(size: 11, weight: .semibold))
                            Spacer()
                        }
                    }
                    ForEach(model.extensions.mcpServers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                MCPLogo(
                                    name: server.name,
                                    url: server.url,
                                    presetID: server.presetID,
                                    size: 30
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(mcpStatusColor(server.state))
                                        .frame(width: 8, height: 8)
                                        .overlay {
                                            Circle().stroke(LocusTheme.white, lineWidth: 1.5)
                                        }
                                        .offset(x: 2, y: 2)
                                }
                                .accessibilityIdentifier("extensions.mcp.server.\(server.id).logo")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).font(.locus(size: 11, weight: .semibold))
                                    Text("\(server.transport.uppercased()) · \(server.state ?? "disconnected") · \(server.toolCount ?? 0) tools")
                                        .font(.locus(size: 8))
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
                                Text(error).font(.locus(size: 8)).foregroundStyle(LocusTheme.coral)
                            }
                            HStack {
                                Menu("Default: \(policyTitle(server.approvalMode))") {
                                    policyButtons(serverID: server.id, tool: nil)
                                }
                                if server.auth == "oauth" || server.auth == "auto" {
                                    Button(server.hasCredentials == true ? "Reconnect account" : "Connect account") {
                                        model.authenticateMCPServer(server)
                                    }
                                } else if server.auth != "none" {
                                    Button(server.hasCredentials == true ? "Update credentials" : "Add credentials") {
                                        credentialServer = server
                                    }
                                }
                                if server.authFallback != nil || server.optionalHeader != nil {
                                    Button(server.hasCredentials == true ? "Update token" : "Use token instead") {
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
                            .font(.locus(size: 9))

                            let tools = model.extensionTools.filter { $0.serverID == server.id }
                            if !tools.isEmpty {
                                DisclosureGroup("Tool permissions") {
                                    ForEach(tools) { tool in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(tool.name).font(.locus(size: 9, weight: .medium, design: .monospaced))
                                                Text(tool.description).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted).lineLimit(1)
                                            }
                                            Spacer()
                                            Menu(policyTitle(tool.approvalMode)) {
                                                policyButtons(serverID: server.id, tool: tool.name)
                                            }
                                        }
                                    }
                                }
                                .font(.locus(size: 9))
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
                    Text("Reusable workflows").font(.locus(size: 11, weight: .semibold))
                    Text("Type $skill in the composer. Locus can also load skills automatically when their metadata matches your request.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
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
                                Text("$\(skill.builtin == true ? skill.name : skill.id)")
                                    .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                                Text(skill.description).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).lineLimit(2)
                                Text([
                                    skill.provenance?.provider ?? skill.source,
                                    skill.shadowed == true ? "superseded by your copy" : nil,
                                    skill.activation == "startup" ? "always on in development chats" : nil,
                                    skill.activation == "explicit" || skill.allowImplicitInvocation == false
                                        ? "explicit only"
                                        : (skill.activation == "startup" ? nil : "automatic or explicit"),
                                ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                            }
                            Spacer()
                            if skill.source == "imported" || skill.builtin == true {
                                let enabledEverywhere = skill.enabledGlobal ?? skill.enabled
                                Button(enabledEverywhere ? "Disable globally" : "Enable globally") {
                                    Task {
                                        await model.setSkill(
                                            skill.id,
                                            enabled: !enabledEverywhere,
                                            scope: "global"
                                        )
                                    }
                                }
                                let enabledHere = skill.disabledWorkspaces?.contains(model.workspacePath) != true
                                    && (enabledEverywhere
                                        || skill.enabledWorkspaces?.contains(model.workspacePath) == true)
                                Button(enabledHere ? "Disable here" : "Enable here") {
                                    Task {
                                        await model.setSkill(
                                            skill.id,
                                            enabled: !enabledHere,
                                            scope: "workspace"
                                        )
                                    }
                                }
                                if skill.source == "imported" {
                                    Button("Remove", role: .destructive) {
                                        Task { await model.removeSkill(skill.id) }
                                    }
                                }
                            } else {
                                Text(skill.enabled ? "Enabled" : "Managed by plugin")
                                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
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

    private func connectPreset(_ preset: ExtensionMCPPreset, projectRef: String) {
        Task {
            guard let server = await model.materializeMCPPreset(preset, projectRef: projectRef) else {
                return
            }
            let probe: @MainActor () async -> Void = {
                if await model.testMCPServer(server.id) {
                    enableAfterProbe = server
                }
            }
            if server.auth == "auto" || server.auth == "oauth" {
                model.authenticateMCPServer(server) { success in
                    if success { Task { await probe() } }
                }
            } else {
                await probe()
            }
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

private struct MCPDeviceAuthorizationView: View {
    @EnvironmentObject private var model: AppModel
    let prompt: MCPDeviceAuthorizationPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MCPLogo(
                    name: prompt.serverName,
                    url: "https://github.com",
                    presetID: "github",
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect GitHub")
                        .font(.locus(size: 14, weight: .bold))
                    Text("Locus opened GitHub's secure device verification page.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            Text(prompt.userCode)
                .font(.locus(size: 24, weight: .bold, design: .monospaced))
                .tracking(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .locusCard(radius: 10)
            Text("Copy this one-time code, enter it on GitHub, then approve the repositories Locus may access. This window closes automatically when sign-in completes.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) {
                    model.cancelMCPDeviceAuthorization()
                }
                Spacer()
                Button("Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.userCode, forType: .string)
                }
                Button("Open GitHub") {
                    NSWorkspace.shared.open(prompt.verificationURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct PluginTrustReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let item: PluginInstallReview
    let install: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.entry.installed ? "Review plugin update" : "Review plugin")
                .font(.locus(size: 16, weight: .bold))
            Text(item.trust.plugin.displayName ?? item.trust.plugin.name)
                .font(.locus(size: 12, weight: .semibold))
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
            .font(.locus(size: 9))
            if !item.trust.trust.skillScripts.isEmpty {
                trustWarning("Skill scripts", item.trust.trust.skillScripts)
            }
            if let diff = item.trust.capabilityDiff, !diff.changes.isEmpty {
                trustWarning("Capability changes", diff.changes)
            }
            ForEach(item.trust.trust.mcpServers, id: \.name) { server in
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP: \(server.name)").font(.locus(size: 10, weight: .semibold))
                    Text(
                        server.transport == "stdio"
                            ? ([server.command].compactMap { $0 } + (server.args ?? [])).joined(separator: " ")
                            : (server.url ?? "Remote endpoint")
                    )
                    if let cwd = server.cwd, !cwd.isEmpty { Text("Working directory: \(cwd)") }
                    if !server.requestedEnv.isEmpty { Text("Environment access: \(server.requestedEnv.joined(separator: ", "))") }
                    if !server.requestedHeaders.isEmpty { Text("Headers: \(server.requestedHeaders.joined(separator: ", "))") }
                }
                .font(.locus(size: 9))
                .padding(8)
                .locusCard(radius: 7)
            }
            if !item.trust.trust.unsupported.isEmpty {
                trustWarning("Not supported by Locus V1", item.trust.trust.unsupported)
            }
            Text("Install only if you trust this publisher and source. Capability changes will require another review.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
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
            Text(title).font(.locus(size: 10, weight: .semibold))
            ForEach(values, id: \.self) { Text("• \($0)").font(.locus(size: 9)) }
        }
        .foregroundStyle(LocusTheme.warning)
    }
}

private struct MCPPresetReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preset: ExtensionMCPPreset
    let connect: (String) -> Void
    @State private var projectRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                MCPLogo(
                    name: preset.displayName,
                    url: preset.url,
                    presetID: preset.id,
                    size: 34
                )
                Text("Review \(preset.displayName) connection")
                    .font(.locus(size: 16, weight: .bold))
            }
            Text(preset.description)
                .font(.locus(size: 10))
                .foregroundStyle(LocusTheme.muted)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow { Text("Host"); Text(URL(string: preset.url)?.host ?? preset.url) }
                if let source = preset.sourceURL, let sourceURL = URL(string: source) {
                    GridRow { Text("Source"); Link("Publisher documentation", destination: sourceURL) }
                }
                GridRow {
                    Text("Sign-in")
                    Text(preset.auth == "auto" ? "OAuth discovery with PKCE" : "Not required")
                }
                GridRow {
                    Text("Scopes")
                    Text(preset.scopes.isEmpty ? "Chosen by the provider during sign-in" : preset.scopes.joined(separator: ", "))
                }
                GridRow { Text("Tools"); Text("Use safety annotations") }
                GridRow { Text("Resources"); Text(preset.resourcesDiscoverable ? "Discoverable" : "Disabled") }
                GridRow { Text("Prompts"); Text(preset.promptsEnabled ? "Allowed" : "Disabled") }
            }
            .font(.locus(size: 9))
            if preset.requiresProjectRef == true {
                TextField("Supabase project reference", text: $projectRef)
                    .textFieldStyle(.roundedBorder)
                Text("The initial URL is project-scoped and read-only. Write access requires an explicit later edit.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }
            Label(preset.warning, systemImage: "hand.raised.fill")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.warning)
            Text("Continue copies this versioned template into your settings while it is disabled. Locus then signs in if needed, probes the server, and asks once more before enabling it.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Continue") { connect(projectRef) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(preset.requiresProjectRef == true && projectRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500, height: 430)
        .background(LocusTheme.panel)
    }
}

private struct MCPEnableReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ExtensionMCPServer
    let enable: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                MCPLogo(
                    name: server.name,
                    url: server.url,
                    presetID: server.presetID,
                    size: 34
                )
                Label("Connection verified", systemImage: "checkmark.shield.fill")
                    .font(.locus(size: 16, weight: .bold))
                    .foregroundStyle(LocusTheme.success)
            }
            Text("\(server.name) completed its tool probe. Enable it now, or keep the reviewed server disabled in Settings.")
                .font(.locus(size: 10))
            Text("The default policy uses MCP safety annotations. Resources are discoverable; server prompts remain disabled until you explicitly allow them.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            Spacer()
            HStack {
                Button("Keep disabled") { dismiss() }
                Spacer()
                Button("Enable for this workspace") { enable("workspace") }
                Button("Enable everywhere") { enable("global") }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
            }
        }
        .padding(18)
        .frame(width: 480, height: 240)
        .background(LocusTheme.panel)
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
    @State private var issuer = ""
    @State private var clientID = ""
    @State private var scopes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add MCP server" : "Edit MCP server")
                .font(.locus(size: 16, weight: .bold))
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
                    Text("OAuth (automatic discovery + PKCE)").tag("auto")
                    Text("OAuth (manual endpoints + PKCE)").tag("oauth")
                }
                if auth == "oauth" {
                    TextField("Issuer (optional; discovers endpoints)", text: $issuer)
                    TextField("Authorization endpoint", text: $authorizationEndpoint)
                    TextField("Token endpoint", text: $tokenEndpoint)
                    TextField("Client ID", text: $clientID)
                    TextField("Scopes, separated by spaces", text: $scopes)
                } else if auth == "auto" {
                    TextField("Client ID or metadata document URL (optional)", text: $clientID)
                    TextField("Requested scopes, separated by spaces (optional)", text: $scopes)
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
                    if auth == "oauth" || auth == "auto" {
                        body["oauth"] = [
                            "issuer": issuer,
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
            issuer = server.oauth?.issuer ?? ""
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
            Text("Credentials for \(server.name)").font(.locus(size: 15, weight: .bold))
            if server.auth == "headers" || server.transport == "stdio" {
                TextField(server.transport == "stdio" ? "Environment variable" : "Header name", text: $fieldName)
            }
            SecureField(server.auth == "bearer" ? "Bearer token" : "Secret value", text: $secret)
            Text("The value is stored in \(MCPCredentialStore.displayName), readable only by your macOS user account. Only the current access token or header is sent to the local agent in memory; OAuth registrations and refresh tokens stay native.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    let values: [String: Any]
                    if server.auth == "bearer" || server.authFallback == "bearer" {
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
        .onAppear {
            fieldName = server.optionalHeader ?? server.fallbackHeader ?? "Authorization"
        }
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
                        .font(.locus(size: 15, weight: .bold))
                    Text("Save and restore the conversation, tasks, workspace, model, and context pack.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.locus())
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
                        .font(.locus(size: 25))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No checkpoints yet")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Create one before a risky or exploratory turn.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.checkpoints) { checkpoint in
                            HStack(spacing: 11) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.locus(size: 14, weight: .semibold))
                                    .foregroundStyle(LocusTheme.signal)
                                    .frame(width: 34, height: 34)
                                    .background(LocusTheme.ink)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(checkpoint.title)
                                        .font(.locus(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.locus(size: 8))
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
                                .buttonStyle(.locus())
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

enum SettingsPresentationContext {
    case sheet
    case settingsWindow
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdateController
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings()
    @State private var localWindow = ""
    @State private var iterationLimit = ""
    @State private var proxyPort = ""
    @State private var proxyAuthEnabled = false
    @State private var proxyPassword = ""
    @State private var proxyPasswordStored = false
    @State private var isTestingProxy = false
    @State private var proxyTestOutcome: ProxyProbe.Outcome?
    @State private var addingAccount: ProviderAccount?
    @State private var editingAccount: ProviderAccount?
    @State private var accountPendingRemoval: ProviderAccount?
    @State private var localModelPendingDeletion: ModelInfo?
    @State private var deletingLocalModelName: String?
    let presentationContext: SettingsPresentationContext

    init(presentationContext: SettingsPresentationContext = .sheet) {
        self.presentationContext = presentationContext
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Locus Settings")
                        .font(.locus(size: 16, weight: .bold))
                    Text("Local agent, models, browser, and account configuration")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.ink)
                        .accessibilityIdentifier("settings.subtitle")
                }
                Spacer()
                Button {
                    model.clearAppearancePreview()
                    dismiss()
                    model.settingsPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Close settings")
                .accessibilityIdentifier("settings.close")
            }
            .padding(17)
            .locusSurface(.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            HStack(spacing: 0) {
                List(SettingsPage.allCases, selection: $model.settingsPage) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(LocusType.callout)
                        // A native sidebar applies vibrancy and its own
                        // selected-row treatment. Use the native semantic
                        // label color here so macOS can resolve the correct
                        // foreground against both states.
                        .foregroundStyle(Color.primary)
                        .tag(item)
                        .accessibilityIdentifier("settings.page.\(item.accessibilityKey)")
                }
                .listStyle(.sidebar)
                .frame(width: 155)

                Rectangle().fill(LocusTheme.line).frame(width: 1)

                switch model.settingsPage {
                case .general: generalPage
                case .network: networkPage
                case .browser: browserPage
                case .accounts: accountsPage
                case .agents:
                    AgentTeamsSettingsView()
                        .environmentObject(model)
                case .knowledge:
                    WorkspaceKnowledgeSettingsView()
                        .environmentObject(model)
                case .permissions: permissionsPage
                case .extensions:
                    ExtensionsSettingsView()
                        .environmentObject(model)
                case .updates: updatesPage
                case .shortcuts:
                    KeyboardShortcutsSettingsView()
                }
            }

            // Network shares General's draft and Save: the proxy has no side
            // effects until Save, and Save is the single point where the
            // settings, the password file, and the agent relaunch commit.
            if model.settingsPage == .general
                || model.settingsPage == .network
                || model.settingsPage == .browser
            {
                HStack {
                    Button("Cancel") {
                        model.clearAppearancePreview()
                        dismiss()
                        model.settingsPresented = false
                    }
                    .accessibilityIdentifier("settings.cancel")
                    Spacer()
                    // Shown wherever the Save bar is: the draft is shared, so
                    // an incomplete proxy disables Save on General too, and a
                    // greyed-out button with no stated reason is a dead end.
                    if let error = proxyDraftError {
                        Text(error)
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.coral)
                            .accessibilityIdentifier("settings.proxyError")
                    }
                    Button("Save") {
                        var saved = draft
                        let typed = localWindow.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.localContextWindow = typed.isEmpty ? nil : Int(typed)
                        let steps = iterationLimit.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.maxIterations = steps.isEmpty ? nil : Int(steps)
                        applyProxyDraft(to: &saved)
                        let credentialChanged = updateProxyCredential(for: saved)
                        model.applySettings(saved, proxyCredentialChanged: credentialChanged)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(proxyDraftError != nil)
                    .accessibilityIdentifier("settings.save")
                }
                .padding(15)
                .locusSurface(.toolbar)
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
                }
            }
        }
        .frame(width: 780, height: 620)
        .background(LocusTheme.panel)
        .onAppear {
            draft = model.settings
            // Seeded, not left blank: these two are held as text rather than in
            // the draft, and an empty field means "clear it" on save — so
            // without this, opening Settings and pressing Save wiped a pinned
            // context window that the user could still see in the meter.
            localWindow = model.settings.localContextWindow.map(String.init) ?? ""
            iterationLimit = model.settings.maxIterations.map(String.init) ?? ""
            proxyPort = model.settings.proxyPort.map(String.init) ?? ""
            proxyTestOutcome = nil
            proxyAuthEnabled = !model.settings.proxyUsername.isEmpty
            // The password field stays empty; the placeholder says one is
            // saved, and an untouched field keeps it — the keyStored pattern.
            proxyPassword = ""
            proxyPasswordStored = model.persistenceEnabled
                && CredentialStore.has(account: CredentialStore.proxyCredentialKey)
        }
        // A result describes the values it was run against; the moment any of
        // them changes it is a claim about a proxy that no longer exists.
        .onChange(of: proxyDraftSignature) { proxyTestOutcome = nil }
        .onChange(of: draft.appearanceRaw) { _, rawValue in
            model.previewAppearance(rawValue)
        }
        .onExitCommand {
            model.clearAppearancePreview()
            dismiss()
            model.settingsPresented = false
        }
        .onDisappear {
            model.clearAppearancePreview()
            if presentationContext == .settingsWindow {
                model.completeSettingsDismissal()
            }
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
        .confirmationDialog(
            "Delete \(localModelPendingDeletion?.name ?? "this model") from this Mac?",
            isPresented: Binding(
                get: { localModelPendingDeletion != nil },
                set: { if !$0 { localModelPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: localModelPendingDeletion
        ) { localModel in
            Button("Delete Downloaded Model", role: .destructive) {
                deletingLocalModelName = localModel.name
                Task {
                    await model.deleteLocalModelFromComputer(localModel)
                    deletingLocalModelName = nil
                    localModelPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { localModelPendingDeletion = nil }
        } message: { localModel in
            Text(
                "This permanently removes "
                    + (localModel.size > 0
                        ? "\(localModel.sizeLabel) of downloaded model data"
                        : "the downloaded model data")
                    + " from Ollama. Chats and notes are kept. You can download the model again later."
            )
        }
    }

    // MARK: - Pages

    /// Everything saved through the draft, plus the runtime readout. Accounts
    /// and permissions each own a tab because both write immediately and have
    /// nothing to do with Cancel/Save.
    private var generalPage: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $draft.appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title)
                            .accessibilityIdentifier("settings.appearance.\(appearance.rawValue)")
                            .tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
                .accessibilityValue(Text(draft.appearanceRaw))

                Text("Selections preview immediately. Save keeps the choice; Cancel restores the saved appearance. System follows your Mac automatically.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Show team progress in the workspace header",
                    isOn: $draft.showTeamProgressInHeader
                )
                .accessibilityIdentifier("settings.showTeamProgressInHeader")

                Toggle(
                    "Show context window usage in the workspace header",
                    isOn: $draft.showContextUsageInHeader
                )
                .accessibilityIdentifier("settings.showContextUsageInHeader")

                Text("Both header status controls are hidden by default. They can also be changed from the workspace’s ellipsis menu.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Agent") {
                TextField("Maximum tool steps per request — all models (optional)", text: $iterationLimit)
                    .accessibilityIdentifier("settings.maxIterations")

                Text("Leave empty for 40. This ceiling applies to local, ChatGPT-plan, and API-backed requests because Locus still coordinates their tool loop. A request that reaches the limit stops and says so.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Conversation") {
                Picker("Store notes by", selection: $draft.notesScopeRaw) {
                    ForEach(NotesScope.allCases) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.notesScope")

                Text("Workspace notes are shared by every chat in the current project. Choose Each chat for separate scratchpads; existing chat notes remain available when you switch back.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(
                    "Solo requests — Context & Plan",
                    selection: $draft.soloPlanPresentationRaw
                ) {
                    ForEach(AutomaticInspectorPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.soloPlanPresentation")

                Picker(
                    "Team & Solo Swarm requests — Runs",
                    selection: $draft.teamRunsPresentationRaw
                ) {
                    ForEach(AutomaticInspectorPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.teamRunsPresentation")

                Text("Solo and team choices are independent. Choosing “Ask the first time” shows the matching explanation when that kind of request is first sent.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }

            Section("Background chats") {
                Stepper(
                    "Up to \(draft.maximumActiveChats) active chats",
                    value: $draft.maximumActiveChats,
                    in: 1...4
                )
                .accessibilityIdentifier("settings.maximumActiveChats")

                Toggle(
                    "Use a worktree for new Git chats",
                    isOn: $draft.newGitChatsUseWorktree
                )
                .accessibilityIdentifier("settings.newGitChatsUseWorktree")

                Stepper(
                    draft.worktreeRetentionLimit == 0
                        ? "Keep all managed worktrees"
                        : "Keep \(draft.worktreeRetentionLimit) recent worktrees",
                    value: $draft.worktreeRetentionLimit,
                    in: 0...100
                )
                .accessibilityIdentifier("settings.worktreeRetentionLimit")

                Text("Running chats stay attached to their own worker when you switch conversations. Worktrees isolate concurrent edits in the same Git repository.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Launch Locus at login", isOn: $draft.launchAtLogin)
                    .accessibilityIdentifier("settings.launchAtLogin")
                Text("Locus starts in the menu bar so schedules can run even when no window is open.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.warning)
                }
            }

            CompanionAccessSettingsSection(enabled: $draft.mobileAccessEnabled)
                .environmentObject(model)

            Section("Terminal") {
                TextField("Shell executable (optional)", text: $draft.terminalShell)
                    .accessibilityIdentifier("settings.terminalShell")
                Toggle("Start as a login shell", isOn: $draft.terminalLoginShell)
                    .accessibilityIdentifier("settings.terminalLoginShell")
                Text("Leave the executable empty to use $SHELL and then /bin/zsh. The terminal runs with your direct input and is separate from agent command permissions.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Local agent") {
                Text("The app includes its own local-agent runtime. These settings are used for custom or development backends.")
                    .font(.locus(size: 9))
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

            Section("Notifications") {
                Toggle(
                    "Notify when a run finishes while Locus is in the background",
                    isOn: $draft.notifyOnCompletion
                )
                .accessibilityIdentifier("settings.notifyOnCompletion")
                Toggle(
                    "Notify when a run needs attention",
                    isOn: $draft.notifyOnNeedsAttention
                )
                .accessibilityIdentifier("settings.notifyOnNeedsAttention")
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
                        .font(.locus(size: 9))
                        .foregroundStyle(runtimeColor(model.modelRuntimePhase))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.ollamaError")
                }
                if !model.backendLogHint.isEmpty {
                    Text(model.backendLogHint)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                if !model.isAgentOnline || !model.isModelOnline {
                    Button("Retry Now") { model.retryLocalServices() }
                        .accessibilityIdentifier("settings.retryLocalServices")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func localModelRow(_ localModel: ModelInfo) -> some View {
        let hidden = model.isLocalModelHidden(localModel.name)
        let current = model.isCurrentRoute(account: nil, model: localModel.name)
        let details = [
            localModel.detail,
            localModel.size > 0 ? localModel.sizeLabel : "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")

        return HStack(spacing: 10) {
            Image(systemName: hidden ? "eye.slash" : "shippingbox.fill")
                .font(.locus(size: 11, weight: .medium))
                .foregroundStyle(hidden ? LocusTheme.muted : LocusTheme.signalDeep)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(localModel.name)
                        .font(.locus(size: 10, weight: .semibold))
                        .lineLimit(1)
                    if current {
                        Text("IN USE")
                            .font(.locus(size: 7, weight: .bold))
                            .foregroundStyle(LocusTheme.signalDeep)
                    }
                    if hidden {
                        Text("REMOVED FROM LOCUS")
                            .font(.locus(size: 7, weight: .bold))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
            }

            Spacer(minLength: 8)

            if deletingLocalModelName == localModel.name {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Deleting \(localModel.name)")
            } else {
                Menu {
                    if hidden {
                        Button("Restore to Locus", systemImage: "arrow.uturn.backward") {
                            model.restoreLocalModelToLocus(localModel)
                        }
                    } else {
                        Button("Remove from Locus", systemImage: "eye.slash") {
                            model.removeLocalModelFromLocus(localModel)
                        }
                    }
                    Divider()
                    Button("Delete from This Mac…", systemImage: "trash", role: .destructive) {
                        localModelPendingDeletion = localModel
                    }
                    .disabled(model.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Manage \(localModel.name)")
                .accessibilityLabel("Manage \(localModel.name)")
                .accessibilityIdentifier("settings.localModels.manage.\(localModel.name)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var browserPage: some View {
        Form {
            Section("Browser") {
                Toggle("Let the agent browse the web", isOn: $draft.browserEnabled)
                    .accessibilityIdentifier("settings.browser.enabled")

                Text("The agent can open pages, read them, and act on them in the Browser tab. Reading never asks. Page JavaScript follows the permission level in Settings → Permissions. Turning this off removes browser tools from the model.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Defaults") {
                TextField("Home URL", text: $draft.previewURL)
                    .accessibilityIdentifier("settings.previewURL")

                Picker("Default viewport", selection: $draft.browserViewportRaw) {
                    ForEach(BrowserViewport.allCases) { viewport in
                        Text(viewport.title).tag(viewport.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.browser.viewport")

                Text("The home page is used when a new Browser tab opens. The viewport can still be changed per tab from the Browser toolbar.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Highlighted text") {
                Picker("Search in Google opens in", selection: $draft.webSearchDestinationRaw) {
                    ForEach(WebSearchDestination.allCases) { destination in
                        Text(destination.title).tag(destination.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.browser.webSearchDestination")

                Text("Right-clicking highlighted text in a conversation offers Copy and Search in Google. The Browser tab is used only while the agent’s browser is on.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Input") {
                Picker("The agent acts on pages with", selection: $draft.browserRealInput) {
                    Text("Real input").tag(true)
                    Text("Synthetic events only").tag(false)
                }
                .accessibilityIdentifier("settings.browser.realInput")

                Text("Real input is delivered the way your own clicks and keystrokes are, so pages see trusted input carrying a user gesture. That is what makes canvases, maps and drag surfaces reachable — and equally what lets a page the agent clicks open a popup or start playback. Synthetic events cannot do either, and a page that checks for trusted input ignores them.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Emulate a mobile device at phone widths", isOn: $draft.browserEmulateDevice)
                    .accessibilityIdentifier("settings.browser.emulateDevice")

                Text("A mobile viewport also presents a mobile user agent, touch points and coarse-pointer media queries, so a site serves what it would serve a phone rather than a narrow desktop.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Developer") {
                Toggle("Allow the Web Inspector to attach", isOn: $draft.browserWebInspector)
                    .accessibilityIdentifier("settings.browser.webInspector")

                Text("Lets Safari's Web Inspector open the agent's pages. Any local process can attach and read the cookies and storage of whatever has been browsed, so leave this off unless you are debugging. Dev servers named in .locus/launch.json can be started by name; the agent lists them for you.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Privacy & data") {
                Picker("Browsing profile", selection: $draft.browserPersistProfile) {
                    Text("Forget when Locus quits").tag(false)
                    Text("Keep per workspace").tag(true)
                }
                .accessibilityIdentifier("settings.browser.persistProfile")

                Text("Forgetting browses ephemerally: cookies, logins, and cache do not outlive the app. Keeping stores a separate profile for each workspace, including that workspace’s signed-in sessions.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Clear Browsing Data…", role: .destructive) {
                    model.browser.clearBrowsingData()
                }
                .accessibilityIdentifier("settings.browser.clearData")
            }
        }
        .formStyle(.grouped)
    }

    /// Outbound proxy. Rides the same draft as General: nothing — settings,
    /// the password file, or the agent relaunch — happens before Save, so
    /// Cancel genuinely leaves no trace.
    private var networkPage: some View {
        Form {
            Section("Proxy") {
                Picker("Outbound traffic", selection: $draft.proxyModeRaw) {
                    Text("Direct connection").tag(ProxyMode.off.rawValue)
                    Text("Use system proxy").tag(ProxyMode.system.rawValue)
                    Text("Manual proxy").tag(ProxyMode.manual.rawValue)
                }
                .accessibilityIdentifier("settings.proxyMode")

                Text(proxyModeDetail)
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if draft.resolvedProxyMode == .system, ProxyConfigurator.systemProxyUsesPAC() {
                    Text("The system proxy is configured through a PAC file, which only the app's own requests can follow — the agent's traffic stays direct. Use a manual proxy to cover everything.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.proxyPACWarning")
                }
            }

            if draft.resolvedProxyMode == .manual {
                Section("Manual proxy") {
                    Picker("Type", selection: $draft.proxyTypeRaw) {
                        Text("HTTP/HTTPS").tag(ProxyType.http.rawValue)
                        Text("SOCKS5").tag(ProxyType.socks5.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.proxyType")

                    TextField("Proxy host", text: $draft.proxyHost)
                        .accessibilityIdentifier("settings.proxyHost")
                    TextField("Port", text: $proxyPort)
                        .accessibilityIdentifier("settings.proxyPort")
                    TextField("Bypass proxy for these hosts (optional)", text: $draft.proxyBypass)
                        .accessibilityIdentifier("settings.proxyBypass")

                    Text("Comma-separated: exact hostnames, IP addresses, or domain suffixes like .corp.example.com. Loopback addresses, the local agent, and the Ollama host always connect directly and do not need listing.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Sign-in") {
                    Toggle("The proxy requires sign-in", isOn: $proxyAuthEnabled)
                        .accessibilityIdentifier("settings.proxyAuth")

                    if proxyAuthEnabled {
                        TextField("Username", text: $draft.proxyUsername)
                            .accessibilityIdentifier("settings.proxyUsername")
                        SecureField(
                            proxyPasswordStored ? "Password (a password is saved)" : "Password",
                            text: $proxyPassword
                        )
                        .accessibilityIdentifier("settings.proxyPassword")

                        Text("The password is written to \(CredentialStore.displayPath) on Save, readable only by your macOS user account. It is used by the app and its agent; commands the model runs see the proxy address but never the password, so they cannot pass its sign-in.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Test") {
                    HStack {
                        Button(isTestingProxy ? "Testing…" : "Test Proxy") { testProxy() }
                            .disabled(isTestingProxy || proxyDraftError != nil)
                            .accessibilityIdentifier("settings.proxyTest")
                        if let outcome = proxyTestOutcome {
                            Text(outcome.message)
                                .font(.locus(size: 9))
                                .foregroundStyle(outcome.ok ? LocusTheme.success : LocusTheme.coral)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.proxyTestResult")
                        }
                    }
                }
            }

            Section {
                Text("The proxy carries the app's own requests, the agent's model and web traffic, extensions, and git. A proxy that stops answering is an error, never a silent direct connection. The agent restarts when these settings change.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var updatesPage: some View {
        Form {
            Section("Installed version") {
                LabeledContent("Locus") {
                    Text(updates.versionLabel)
                        .accessibilityIdentifier("settings.updateVersion")
                }
            }

            Section("Software updates") {
                if updates.isAvailable {
                    Toggle(
                        "Automatically check for updates",
                        isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.setAutomaticallyChecksForUpdates($0) }
                        )
                    )
                    .accessibilityIdentifier("settings.automaticUpdateChecks")

                    Toggle(
                        "Download and install updates automatically",
                        isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates },
                            set: { updates.setAutomaticallyDownloadsUpdates($0) }
                        )
                    )
                    .disabled(!updates.automaticallyChecksForUpdates)
                    .accessibilityIdentifier("settings.automaticUpdateDownloads")

                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityIdentifier("settings.checkForUpdates")

                    Text("Locus checks the stable release channel daily. Updates download securely in the background and install when Locus quits. If an update needs administrator approval, macOS asks before installing it.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(
                        "Updates are installed through the Mac App Store.",
                        systemImage: "shippingbox.fill"
                    )
                    .font(.locus(size: 10))
                    .accessibilityIdentifier("settings.appStoreUpdates")

                    Text("Keep automatic updates enabled in the App Store to receive new Locus releases without downloading them manually.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            componentsSection
        }
        .formStyle(.grouped)
    }

#if LOCUS_APP_STORE
    /// The App Store build bundles every helper it needs.
    @ViewBuilder
    private var componentsSection: some View { EmptyView() }
#else
    /// ChatGPT-plan support is the one piece of Locus that is fetched rather
    /// than shipped. It is surfaced here so it can be reclaimed without hunting
    /// through the account editor that installed it.
    @ViewBuilder
    private var componentsSection: some View {
        Section("Components") {
            if CodexComponent.isInstalled {
                LabeledContent("ChatGPT plan support") {
                    Text(componentSizeLabel)
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("settings.componentSize")
                }
                Button("Remove", role: .destructive) {
                    Task { await model.codexComponent.remove() }
                }
                .accessibilityIdentifier("settings.removeComponent")
                Text("Removing this frees the space now. Locus offers it again the next time you use a ChatGPT-plan account.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("ChatGPT plan support is not installed", systemImage: "shippingbox")
                    .font(.locus(size: 10))
                    .accessibilityIdentifier("settings.componentAbsent")
                Text("Add a ChatGPT-plan account to download it. Ollama, API-key and custom-endpoint accounts do not need it.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var componentSizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        let version = CodexComponent.installedVersion().map { " · \($0)" } ?? ""
        return formatter.string(fromByteCount: CodexComponent.installedBytes()) + version
    }
#endif

    /// Everything a proxy test depends on, so editing any of it retires the
    /// last result rather than leaving it to describe a stale configuration.
    private var proxyDraftSignature: String {
        [
            draft.proxyModeRaw, draft.proxyTypeRaw, draft.proxyHost, proxyPort,
            draft.proxyBypass, draft.proxyUsername, proxyPassword,
            proxyAuthEnabled ? "1" : "0",
        ].joined(separator: "\u{1F}")
    }

    private var proxyModeDetail: String {
        switch draft.resolvedProxyMode {
        case .off:
            "Connections go straight out, the way Locus has always worked."
        case .system:
            "The app follows the proxy configured in System Settings, and the agent is launched with the matching HTTP_PROXY environment."
        case .manual:
            "Everything — the app and the agent — is routed through the proxy below, except loopback and the bypass list."
        }
    }

    /// Manual mode must be complete before Save can commit it: a half-typed
    /// proxy silently falling back to direct connections is the one outcome
    /// this feature exists to prevent.
    private var proxyDraftError: String? {
        guard draft.resolvedProxyMode == .manual else { return nil }
        let host = ProxyConfigurator.normalizedHost(draft.proxyHost)
        let typed = proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = AppSettings.clampProxyPort(typed.isEmpty ? nil : Int(typed))
        if host.isEmpty || port == nil {
            return "Manual proxy needs a host and a port from 1 to 65535."
        }
        guard proxyAuthEnabled else { return nil }
        if draft.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Sign-in needs a username, or turn sign-in off."
        }
        // A saved password left untouched is fine; nothing at all is not —
        // it would save a username the proxy answers every request with 407.
        if !proxyPasswordStored,
           proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Sign-in needs a password, or turn sign-in off."
        }
        return nil
    }

    private func applyProxyDraft(to saved: inout AppSettings) {
        saved.proxyHost = ProxyConfigurator.normalizedHost(draft.proxyHost)
        let typed = proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.proxyPort = AppSettings.clampProxyPort(typed.isEmpty ? nil : Int(typed))
        saved.proxyUsername = proxyAuthEnabled
            ? draft.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    /// Writes or deletes the proxy password — from Save only, so Cancel
    /// cannot leave a half-committed credential. Returns whether anything
    /// about the stored secret changed, which is what forces the relaunch.
    private func updateProxyCredential(for saved: AppSettings) -> Bool {
        // Tests run against isolated defaults but a real credential file; the
        // delete branch below would otherwise wipe the developer's password.
        guard model.persistenceEnabled else { return false }
        if saved.proxyUsername.isEmpty {
            guard proxyPasswordStored else { return false }
            CredentialStore.setProxyPassword("")
            return true
        }
        let typed = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != CredentialStore.proxyPassword() else { return false }
        return CredentialStore.setProxyPassword(typed)
    }

    /// Probes with the *draft* values, like Test Connection on an account:
    /// side-effect free, nothing saved, the live sessions untouched.
    private func testProxy() {
        var candidate = draft
        applyProxyDraft(to: &candidate)
        let typedPassword = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = typedPassword.isEmpty ? CredentialStore.proxyPassword() : typedPassword
        guard let proxy = ProxyConfigurator.resolved(
            settings: candidate,
            password: password,
            ollamaHost: nil
        ) else { return }
        // The active provider makes the probe meaningful; without one — or
        // with a local one, which proves nothing about a proxy — a host the
        // app already talks to for the model library.
        let base = model.activeAccount
            .map { RemoteEndpointTester.normalizeBaseURL($0.resolvedBaseURL) }
            .flatMap(URL.init(string:))
            .flatMap { OllamaRuntime.isLoopback($0) ? nil : $0 }
        let target = base ?? URL(string: "https://huggingface.co")!
        isTestingProxy = true
        proxyTestOutcome = nil
        Task {
            let outcome = await ProxyProbe.test(proxy: proxy, target: target)
            isTestingProxy = false
            proxyTestOutcome = outcome
        }
    }

    /// Remote provider accounts. Edits here write the credential file as they
    /// happen, so this page has no Cancel/Save bar of its own.
    private var accountsPage: some View {
        Form {
            Section("Provider accounts") {
                if model.providerAccounts.isEmpty {
                    Text("No accounts yet — Locus runs on local Ollama until you add one.")
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("settings.accounts.empty")
                }

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
                                .font(.locus(size: 11, weight: .semibold))
                            Text(accountDetail(account))
                                .font(.locus(size: 9))
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

                Text("API accounts keep their keys in \(CredentialStore.displayPath), readable only by your macOS user account. ChatGPT plan sign-in is isolated in OpenAI's managed runtime and its tokens never enter Locus account files.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Local model") {
                Label(
                    "Local Ollama needs no account — models installed on this Mac appear in the picker automatically.",
                    systemImage: "bolt.fill"
                )
                .font(.locus(size: 10))
                .foregroundStyle(LocusTheme.muted)

                if model.installedLocalModels.isEmpty {
                    Text(model.isModelOnline
                        ? "No local models are installed."
                        : "Connect to Ollama to see installed models.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                } else {
                    ForEach(model.installedLocalModels) { localModel in
                        localModelRow(localModel)
                    }
                }

                HStack {
                    Button("Browse Hugging Face Models…") {
                        model.openModelLibraryFromSettings()
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.accounts.browseHuggingFace")

                    Button("Refresh") {
                        Task { await model.refreshMetadata() }
                    }
                    .disabled(deletingLocalModelName != nil)
                    .accessibilityIdentifier("settings.localModels.refresh")
                }

                TextField("Local context window in tokens (optional)", text: $localWindow)
                    .accessibilityIdentifier("settings.localContextWindow")

                Text("Leave empty and Locus asks Ollama for the largest window the model was built for, up to 32,768 tokens — Ollama's own default is 4,096, most of which a turn spends on tools before the conversation starts. Bigger windows cost memory for the KV cache, and a model that ends up partly on the CPU is backed off automatically. Set a value to pin one exactly; it is requested as num_ctx and is what compaction budgets against.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.localContextDescription")
            }
        }
        .formStyle(.grouped)
    }

    /// Permission mode applies the moment it changes — the agent may already be
    /// mid-turn — so this page, too, stands apart from the draft.
    private var permissionsPage: some View {
        Form {
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
                    .font(.locus(size: 9))
                    .foregroundStyle(
                        model.permissionMode.isRisky ? LocusTheme.coral : LocusTheme.muted
                    )
                    .fixedSize(horizontal: false, vertical: true)

                if !model.allowedTools.isEmpty {
                    LabeledContent("Always allowed") {
                        Text(model.allowedTools.joined(separator: ", "))
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }

                Button("Reset session allowances") { model.resetPermissions() }
                    .disabled(model.allowedTools.isEmpty && model.permissionMode == .ask)
                    .accessibilityIdentifier("settings.resetPermissions")

                Text("Ask and Accept File Edits confirm access outside the workspace. Full Access skips those confirmations, while the deny list and credential/transaction takeover rules still apply.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Label("macOS folder access is separate", systemImage: "folder.badge.questionmark")
                    .font(.locus(size: 9, weight: .semibold))
                Text("Full Access controls agent tool approvals. macOS may still ask Locus itself for Documents, Desktop, Accessibility, or Screen Recording access. A stable signed app normally remembers that system choice; rebuilding or launching a differently signed copy can make macOS ask again.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Computer Control") {
                if ComputerControlService.isAvailable {
                    Toggle("Allow Locus to control Mac apps", isOn: Binding(
                        get: { model.settings.computerControlEnabled },
                        set: { model.setComputerControlEnabled($0) }
                    ))
                    .accessibilityIdentifier("settings.computerControl.enabled")

                    Text("Off by default. Read-only app inspection is automatic. Clicks, typing, keys, scrolling, and dragging follow the permission mode above, with non-bypassable safeguards for credentials and high-consequence actions.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Accessibility") {
                        permissionStatus(
                            granted: model.computerControl.accessibilityGranted,
                            grant: model.computerControl.requestAccessibility,
                            settings: model.computerControl.openAccessibilitySettings
                        )
                    }
                    LabeledContent("Screen Recording") {
                        permissionStatus(
                            granted: model.computerControl.screenRecordingGranted,
                            grant: model.computerControl.requestScreenRecording,
                            settings: model.computerControl.openScreenRecordingSettings
                        )
                    }
                    Text("Screenshots are target-window scoped and exclude Locus. Before a screenshot is sent to a hosted provider, Locus names that provider and asks once per session. Local Ollama screenshots remain local.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Unavailable in the Mac App Store build", systemImage: "lock.app.dashed")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Apple requires App Sandbox for Mac App Store apps, while assistive Accessibility control is incompatible with that sandbox. Install the signed direct-download build to opt in.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(
                        "Apple App Sandbox guidance",
                        destination: URL(string: "https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox")!
                    )
                    .font(.locus(size: 9, weight: .semibold))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.computerControl.refreshPermissionStatus() }
    }

    @ViewBuilder
    private func permissionStatus(
        granted: Bool,
        grant: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? LocusTheme.success : LocusTheme.warning)
            if !granted {
                Button("Grant", action: grant)
                Button("Open Settings", action: settings)
            }
        }
        .font(.locus(size: 9, weight: .semibold))
    }

    private func accountDetail(_ account: ProviderAccount) -> String {
        let status = model.accountStatus[account.id]
            ?? (account.hasKey ? .keySaved : .noKey)
        if account.kind == .chatGPT,
           let window = model.chatGPTUsageByAccount[account.id]?.rateLimits.rateLimits?.primary
        {
            let reset = window.resetsAt.map {
                "resets " + Date(timeIntervalSince1970: Double($0))
                    .formatted(.relative(presentation: .named))
            }
            let activity = model.chatGPTUsageByAccount[account.id]?
                .activity.summary?.lifetimeTokens.map {
                $0.formatted(.number.notation(.compactName)) + " activity tokens"
            }
            return [status.summary, "\(window.usedPercent)% used", reset, activity]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
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
