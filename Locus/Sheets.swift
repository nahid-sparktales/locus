import AVFoundation
import Speech
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
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    private enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case marketplace = "Marketplace"
        case mcp = "MCP Servers"
        case skills = "Skills"
        var id: String { rawValue }
    }

    private struct RecommendedPlugin: Identifiable {
        let name: String
        let purpose: String
        let permissions: String
        let symbol: String
        var id: String { name }
    }

    private static let recommendedPluginBacklog = [
        RecommendedPlugin(
            name: "Linear",
            purpose: "Issues, roadmaps, and implementation context.",
            permissions: "teams, projects, issues, and comments",
            symbol: "checklist"
        ),
        RecommendedPlugin(
            name: "Slack",
            purpose: "Team discussions, approvals, and incident coordination.",
            permissions: "selected workspaces and channels",
            symbol: "bubble.left.and.bubble.right"
        ),
        RecommendedPlugin(
            name: "Sentry",
            purpose: "Production errors, traces, releases, and service health.",
            permissions: "selected organizations and projects",
            symbol: "waveform.path.ecg"
        ),
        RecommendedPlugin(
            name: "PostHog",
            purpose: "Product analytics, sessions, and feature flags.",
            permissions: "selected projects and analytics data",
            symbol: "chart.xyaxis.line"
        ),
        RecommendedPlugin(
            name: "Notion",
            purpose: "Specifications, decisions, and internal documentation.",
            permissions: "explicitly shared pages and databases",
            symbol: "doc.text"
        ),
    ]

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

            if let error = extensionsModel.extensionErrorMessage, !error.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { extensionsModel.extensionErrorMessage = nil }
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
            await extensionsModel.refreshExtensions()
            await extensionsModel.refreshExtensionCatalog()
        }
        .sheet(item: $review) { item in
            PluginTrustReviewView(item: item) { scope in
                review = nil
                Task { await extensionsModel.installPlugin(item.entry, trust: item.trust, scope: scope) }
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
            MCPPresetReviewView(preset: preset) { projectRef, useTokenFallback in
                presetReview = nil
                connectPreset(
                    preset,
                    projectRef: projectRef,
                    useTokenFallback: useTokenFallback
                )
            }
            .environmentObject(model)
        }
        .sheet(item: $enableAfterProbe) { server in
            MCPEnableReviewView(server: server) { scope in
                enableAfterProbe = nil
                Task { await extensionsModel.setMCPServer(server.id, enabled: true, scope: scope) }
            }
        }
        .sheet(item: Binding(
            get: { extensionsModel.mcpDeviceAuthorization },
            set: { extensionsModel.mcpDeviceAuthorization = $0 }
        )) { prompt in
            MCPDeviceAuthorizationView(prompt: prompt)
                .environmentObject(model)
        }
    }

    private var installedPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if extensionsModel.extensions.plugins.isEmpty {
                    ContentUnavailableView(
                        "No plugins installed",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Choose a source in Marketplace, then review and install a plugin.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 330)
                }
                ForEach(extensionsModel.extensions.plugins) { plugin in
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
                                Task { await extensionsModel.setPlugin(plugin.id, enabled: !plugin.enabledGlobal, scope: "global") }
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
                                Task { await extensionsModel.setPlugin(plugin.id, enabled: !workspaceEnabled, scope: "workspace") }
                            }
                            .disabled(model.isBusy)
                            if !(plugin.previousVersions ?? []).isEmpty {
                                Button("Roll back") { Task { await extensionsModel.rollbackPlugin(plugin.id) } }
                                    .disabled(model.isBusy)
                            }
                            if plugin.updateAvailable == true {
                                Button("Review update") {
                                    Task {
                                        if let (entry, trust) = await extensionsModel.inspectUpdate(for: plugin) {
                                            review = PluginInstallReview(entry: entry, trust: trust)
                                        }
                                    }
                                }
                                .disabled(model.isBusy)
                            }
                            Spacer()
                            Button("Uninstall", role: .destructive) {
                                Task { await extensionsModel.uninstallPlugin(plugin.id) }
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
                    ForEach(extensionsModel.extensions.marketplaces) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .frame(maxWidth: 230)
                TextField("Search plugins", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await extensionsModel.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
                    }
                Button("Search") {
                    Task { await extensionsModel.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
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
                    Task { await extensionsModel.addMarketplace(source: source, name: marketplaceName) }
                }
                .disabled(marketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.locus(size: 9))

            ScrollView {
                LazyVStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recommended next")
                                .font(.locus(size: 11, weight: .semibold))
                            Spacer()
                            Text("Opt-in · review permissions before install")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        ForEach(Self.recommendedPluginBacklog) { recommendation in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: recommendation.symbol)
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(LocusTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recommendation.name)
                                        .font(.locus(size: 10, weight: .semibold))
                                    Text(recommendation.purpose)
                                        .font(.locus(size: 9))
                                        .foregroundStyle(LocusTheme.muted)
                                    Text("Review: \(recommendation.permissions)")
                                        .font(.locus(size: 8))
                                        .foregroundStyle(LocusTheme.warning)
                                }
                                Spacer()
                                Button("Find") {
                                    search = recommendation.name
                                    Task {
                                        await extensionsModel.refreshExtensionCatalog(
                                            query: recommendation.name,
                                            marketplaceID: marketplaceID
                                        )
                                    }
                                }
                            }
                            .padding(9)
                            .locusCard(radius: 8)
                        }
                    }
                    .padding(.bottom, 6)

                    ForEach(extensionsModel.extensionCatalog) { entry in
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
                                    if let trust = await extensionsModel.inspectPlugin(entry) {
                                        review = PluginInstallReview(entry: entry, trust: trust)
                                    }
                                }
                            }
                            .disabled(!entry.available || model.isBusy)
                        }
                        .padding(11)
                        .locusCard(radius: 9)
                    }
                    if extensionsModel.extensionCatalog.isEmpty {
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
            Task { await extensionsModel.refreshExtensionCatalog(query: search, marketplaceID: marketplaceID) }
        }
    }

    private var mcpPane: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("External tools from MCP servers")
                        .font(.locus(size: 11, weight: .semibold))
                    if !extensionsModel.extensions.capabilities.stdio {
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
                    if !extensionsModel.extensions.mcpPresets.isEmpty {
                        HStack {
                            Text("Recommended")
                                .font(.locus(size: 11, weight: .semibold))
                            Spacer()
                            Text("Bundled templates · no startup network access")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        ForEach(extensionsModel.extensions.mcpPresets) { preset in
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
                    ForEach(extensionsModel.extensions.mcpServers) { server in
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
                                Button("Test") { Task { await extensionsModel.testMCPServer(server.id) } }
                                    .disabled(model.isBusy)
                                Button("Reconnect") { Task { await extensionsModel.reconnectMCPServer(server.id) } }
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
                            if server.presetID == "github",
                               extensionsModel.githubConnectionCapability(for: server) == .tokenFallbackOnly {
                                Label(
                                    "This build has no GitHub App client ID. Account sign-in is disabled; use a personal token instead.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.coral)
                                .accessibilityIdentifier("extensions.github.capability.tokenFallbackOnly")
                            }
                            HStack {
                                Menu("Default: \(policyTitle(server.approvalMode))") {
                                    policyButtons(serverID: server.id, tool: nil)
                                }
                                if server.auth == "oauth" || server.auth == "auto" {
                                    Button(server.hasCredentials == true ? "Reconnect account" : "Connect account") {
                                        extensionsModel.authenticateMCPServer(server)
                                    }
                                    .disabled(
                                        server.presetID == "github"
                                            && extensionsModel.githubConnectionCapability(for: server) == .tokenFallbackOnly
                                    )
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
                                        Task { await extensionsModel.clearMCPCredentials(serverID: server.id) }
                                    }
                                }
                                Spacer()
                                let workspaceEnabled = server.disabledWorkspaces?.contains(model.workspacePath) != true
                                    && (server.enabledGlobal == true || server.enabledWorkspaces?.contains(model.workspacePath) == true)
                                if let pluginID = server.pluginID {
                                    Button(workspaceEnabled ? "Disable plugin here" : "Enable plugin here") {
                                        Task { await extensionsModel.setPlugin(pluginID, enabled: !workspaceEnabled, scope: "workspace") }
                                    }
                                } else {
                                    Button(workspaceEnabled ? "Disable here" : "Enable here") {
                                        Task { await extensionsModel.setMCPServer(server.id, enabled: !workspaceEnabled, scope: "workspace") }
                                    }
                                }
                                if server.origin == "user" {
                                    Button("Remove", role: .destructive) {
                                        Task { await extensionsModel.removeMCPServer(server.id) }
                                    }
                                }
                            }
                            .font(.locus(size: 9))

                            let tools = extensionsModel.extensionTools.filter { $0.serverID == server.id }
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
                    ForEach(extensionsModel.extensions.skills) { skill in
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
                                        await extensionsModel.setSkill(
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
                                        await extensionsModel.setSkill(
                                            skill.id,
                                            enabled: !enabledHere,
                                            scope: "workspace"
                                        )
                                    }
                                }
                                if skill.source == "imported" {
                                    Button("Remove", role: .destructive) {
                                        Task { await extensionsModel.removeSkill(skill.id) }
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
        Button("Use annotations") { Task { await extensionsModel.setMCPPolicy(serverID: serverID, tool: tool, mode: "annotations") } }
        Button("Ask") { Task { await extensionsModel.setMCPPolicy(serverID: serverID, tool: tool, mode: "ask") } }
        Button("Allow") { Task { await extensionsModel.setMCPPolicy(serverID: serverID, tool: tool, mode: "allow") } }
        Button("Disabled") { Task { await extensionsModel.setMCPPolicy(serverID: serverID, tool: tool, mode: "disabled") } }
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

    private func connectPreset(
        _ preset: ExtensionMCPPreset,
        projectRef: String,
        useTokenFallback: Bool = false
    ) {
        Task {
            guard let server = await extensionsModel.materializeMCPPreset(preset, projectRef: projectRef) else {
                return
            }
            if useTokenFallback {
                credentialServer = server
                return
            }
            let probe: @MainActor () async -> Void = {
                if await extensionsModel.testMCPServer(server.id) {
                    enableAfterProbe = server
                }
            }
            if server.auth == "auto" || server.auth == "oauth" {
                extensionsModel.authenticateMCPServer(server) { success in
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
            Task { await extensionsModel.importSkill(from: url.path) }
        }
    }
}

private struct MCPDeviceAuthorizationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
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
                    extensionsModel.cancelMCPDeviceAuthorization()
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    let preset: ExtensionMCPPreset
    let connect: (String, Bool) -> Void
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
            if preset.id == "github", githubCapability == .tokenFallbackOnly {
                Label(
                    "Account sign-in is unavailable because this build has no Locus GitHub App client ID. A personal token can still be stored in Keychain.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityIdentifier("extensions.github.capability.tokenFallbackOnly")
            }
            Text("Continue copies this versioned template into your settings while it is disabled. Locus then signs in if needed, probes the server, and asks once more before enabling it.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if preset.id == "github", githubCapability == .tokenFallbackOnly {
                    Button("Use token instead") { connect(projectRef, true) }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                } else {
                    Button("Continue") { connect(projectRef, false) }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        .disabled(preset.requiresProjectRef == true && projectRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 500, height: 430)
        .background(LocusTheme.panel)
    }

    private var githubCapability: GitHubConnectionCapability {
        extensionsModel.githubConnectionCapability()
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
    @EnvironmentObject private var extensionsModel: ExtensionsModel
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
                    if !extensionsModel.extensions.capabilities.stdio {
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
                    Task { await extensionsModel.saveMCPServer(body) }
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
    @EnvironmentObject private var extensionsModel: ExtensionsModel
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
                    Task { await extensionsModel.setMCPCredentials(serverID: server.id, values: values) }
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
                    Text("Manual session checkpoints")
                        .font(.locus(size: 15, weight: .bold))
                    Text("Chats already autosave. Add a named rollback point when you want to restore the conversation, tasks, workspace, model, and context pack together.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @EnvironmentObject private var voiceControl: VoiceControlModel
    @EnvironmentObject private var applicationContext: ApplicationContextService
    @EnvironmentObject private var computerControl: ComputerControlService
    @EnvironmentObject private var simulatorControl: SimulatorControlService
#if !LOCUS_APP_STORE
    @EnvironmentObject private var codexComponent: CodexComponentInstaller
#endif
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
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
    @State private var settingsSearch = ""
    @State private var pendingSearchAnchor: String?
    @State private var expandedAdvancedPages: Set<SettingsPage> = []
    @State private var hasLoadedDraft = false
    @State private var discardPromptPresented = false
    @State private var lifecycleRegistrationID = UUID()
    @FocusState private var focusedTextPreference: String?
    let presentationContext: SettingsPresentationContext

    init(presentationContext: SettingsPresentationContext = .sheet) {
        self.presentationContext = presentationContext
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Rectangle()
                .fill(LocusTheme.separator)
                .frame(width: 1)

            VStack(spacing: 0) {
                settingsDetailHeader

                if settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settingsPageContent
                } else {
                    settingsSearchResults
                }

                settingsActionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 680)
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
            hasLoadedDraft = true
            model.registerSettingsUpdatePreparation(id: lifecycleRegistrationID) {
                prepareSettingsForUpdate()
            }
        }
        // A result describes the values it was run against; the moment any of
        // them changes it is a claim about a proxy that no longer exists.
        .onChange(of: proxyDraftSignature) { proxyTestOutcome = nil }
        .onChange(of: immediateDraftSignature) {
            guard hasLoadedDraft else { return }
            applyImmediateDraft()
        }
        .onChange(of: focusedTextPreference) { oldValue, newValue in
            guard hasLoadedDraft, oldValue != nil, oldValue != newValue else { return }
            applyImmediateDraft()
        }
        .onExitCommand {
            requestSettingsDismissal()
        }
        .interactiveDismissDisabled(hasAnyStagedChanges)
        .onDisappear {
            expandedAdvancedPages.removeAll()
            model.unregisterSettingsUpdatePreparation(id: lifecycleRegistrationID)
            model.clearAppearancePreview()
            if presentationContext == .settingsWindow {
                model.completeSettingsDismissal()
            }
        }
        .alert("Discard unapplied settings?", isPresented: $discardPromptPresented) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive) {
                discardAllStagedChanges()
                completeSettingsDismissal()
            }
        } message: {
            Text("Network, model runtime, or developer changes have not been applied.")
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

    // MARK: - Studio settings shell

    private func advancedBinding(for page: SettingsPage) -> Binding<Bool> {
        Binding(
            get: { expandedAdvancedPages.contains(page) },
            set: { expanded in
                if expanded {
                    expandedAdvancedPages.insert(page)
                } else {
                    expandedAdvancedPages.remove(page)
                }
            }
        )
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(.title2, design: .default, weight: .bold))
                .foregroundStyle(LocusTheme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LocusTheme.textTertiary)
                TextField("Search settings", text: $settingsSearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search settings")
                    .accessibilityIdentifier("settings.search")
                if !settingsSearch.isEmpty {
                    Button {
                        settingsSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LocusTheme.textTertiary)
                    }
                    .buttonStyle(.locus())
                    .accessibilityLabel("Clear settings search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(LocusTheme.surfaceCard.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.separator, lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(SettingsNavigationGroup.allCases) { group in
                        Text(group.rawValue.uppercased())
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(LocusTheme.textTertiary)
                            .padding(.horizontal, 11)
                            .padding(.top, 11)
                            .padding(.bottom, 3)

                        ForEach(visiblePages(in: group)) { page in
                            settingsNavigationButton(page)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .accessibilityIdentifier("settings.navigation")

        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .locusSurface(.structural)
    }

    private func visiblePages(in group: SettingsNavigationGroup) -> [SettingsPage] {
        SettingsPage.allCases.filter { $0.navigationGroup == group }
    }

    private func settingsNavigationButton(_ page: SettingsPage) -> some View {
        Button {
            settingsSearch = ""
            model.settingsPage = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasStagedChanges(for: page) {
                    Circle()
                        .fill(LocusTheme.accentAction)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unapplied changes")
                }
            }
            .foregroundStyle(
                model.settingsPage == page ? LocusTheme.textPrimary : LocusTheme.textSecondary
            )
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                model.settingsPage == page
                    ? LocusTheme.surfaceCard.opacity(0.86) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityIdentifier("settings.page.\(page.accessibilityKey)")
    }

    private var settingsDetailHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settingsSearch.isEmpty ? model.settingsPage.rawValue : "Search Settings")
                    .font(.system(.title2, design: .default, weight: .bold))
                    .foregroundStyle(LocusTheme.textPrimary)
                Text(settingsSearch.isEmpty
                    ? model.settingsPage.subtitle
                    : "Choose a result to open the matching control.")
                    .font(.system(.callout, design: .default))
                    .foregroundStyle(LocusTheme.textTertiary)
                    .accessibilityIdentifier("settings.subtitle")
            }
            Spacer()
            Button { requestSettingsDismissal() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(LocusTheme.surfaceCard.opacity(0.8))
                    .clipShape(Circle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Close settings")
            .accessibilityIdentifier("settings.close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private var settingsPageContent: some View {
        ScrollViewReader { proxy in
            Group {
                switch model.settingsPage {
                case .general: generalPage
                case .appearance: appearancePage
                case .chat: chatPage
                case .network: networkPage
                case .browser: browserPage
                case .wallet:
                    WalletSettingsView(
                        gateway: model.walletGateway,
                        rpcURL: $draft.walletSepoliaRPCURL,
                        alphaEnabled: $draft.walletAlphaEnabled,
                        browserEnabled: $draft.walletBrowserProviderEnabled
                    )
                case .accounts: accountsPage
                case .agents:
                    AgentTeamsSettingsView(advancedExpanded: advancedBinding(for: .agents))
                        .environmentObject(model)
                case .knowledge:
                    WorkspaceKnowledgeSettingsView(advancedExpanded: advancedBinding(for: .knowledge))
                        .environmentObject(model)
                case .permissions: permissionsPage
                case .extensions:
                    ExtensionsSettingsView()
                        .environmentObject(model)
                case .developer: developerPage
                case .updates: updatesPage
                case .shortcuts:
                    KeyboardShortcutsSettingsView()
                }
            }
            .id(model.settingsPage)
            .accessibilityIdentifier("settings.content.\(model.settingsPage.accessibilityKey)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: pendingSearchAnchor) { _, anchor in
                guard let anchor else { return }
                guard model.settingsPage != .browser else { return }
                withAnimation(LocusMotion.scroll) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
                pendingSearchAnchor = nil
            }
        }
    }

    private var settingsSearchResults: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Settings Found",
                        systemImage: "magnifyingglass",
                        description: Text("Try a feature, control, or category name.")
                    )
                    .padding(.top, 90)
                } else {
                    ForEach(searchResults) { result in
                        Button { openSearchResult(result) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: result.page.symbol)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(LocusTheme.accentAction)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 7) {
                                        Text(result.title)
                                            .font(.system(.body, design: .default, weight: .semibold))
                                        if result.isAdvanced {
                                            Text("ADVANCED")
                                                .font(.system(.caption2, design: .default, weight: .bold))
                                                .foregroundStyle(LocusTheme.textTertiary)
                                        }
                                    }
                                    Text(result.page.rawValue)
                                        .font(.system(.caption, design: .default))
                                        .foregroundStyle(LocusTheme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(LocusTheme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 58)
                            .background(LocusTheme.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(LocusTheme.separator, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.locus())
                        .accessibilityIdentifier("settings.search.result.\(result.id)")
                    }
                }
            }
            .frame(maxWidth: 660)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var searchResults: [SettingsSearchDescriptor] {
        SettingsSearchDescriptor.all.filter { $0.matches(settingsSearch) }
    }

    private func openSearchResult(_ result: SettingsSearchDescriptor) {
        if result.isAdvanced {
            expandedAdvancedPages.insert(result.page)
        }
        model.settingsPage = result.page
        pendingSearchAnchor = result.anchor
        settingsSearch = ""
    }

    private var settingsActionBar: some View {
        HStack(spacing: 10) {
            if let error = model.settingsPage == .network ? proxyDraftError : nil {
                Text(error)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(LocusTheme.dangerForeground)
                    .accessibilityIdentifier("settings.proxyError")
            } else if currentPageHasStagedChanges {
                Text("Unapplied changes")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(LocusTheme.textTertiary)
            }
            Spacer()
            if isStagedPage(model.settingsPage) {
                Button("Discard") { discardStagedChanges(for: model.settingsPage) }
                    .disabled(!currentPageHasStagedChanges)
                    .accessibilityIdentifier("settings.discard")
                Button("Apply") { applyStagedPage(model.settingsPage) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!currentPageHasStagedChanges || stagedPageHasError)
                    .accessibilityIdentifier("settings.save")
            }
            Button("Close") { requestSettingsDismissal() }
                .accessibilityIdentifier("settings.cancel")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .locusSurface(.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.separator).frame(height: 1)
        }
    }

    private var immediateDraftSignature: String {
        [
            draft.appearanceRaw,
            draft.accentPresetRaw, draft.customAccentHex,
            draft.showTeamProgressInHeader.description,
            draft.showContextUsageInHeader.description,
            draft.notesScopeRaw, draft.soloPlanPresentationRaw,
            draft.teamRunsPresentationRaw, draft.thinkingVisibilityRaw,
            draft.toolActivityVisibilityRaw, draft.maximumActiveChats.description,
            draft.worktreeRetentionLimit.description,
            draft.newGitChatsUseWorktree.description, draft.launchAtLogin.description,
            draft.mobileAccessEnabled.description, draft.notifyOnCompletion.description,
            draft.notifyOnNeedsAttention.description, draft.browserEnabled.description,
            draft.voiceControlsEnabled.description, draft.voiceSpeechEngineRaw,
            draft.voiceCloudAccountID ?? "", draft.voiceLanguageIdentifier,
            draft.voiceSystemVoiceIdentifier,
            draft.voiceAppleNetworkRecognitionAllowed.description,
            draft.voiceSendBehaviorRaw, draft.voiceCloudTranscriptionModel,
            draft.voiceCloudSpeechModel, draft.voiceCloudVoiceIdentifier,
            draft.browserViewportRaw, draft.browserPersistProfile.description,
            draft.browserRealInput.description, draft.browserEmulateDevice.description,
            draft.browserWebInspector.description, draft.webSearchDestinationRaw,
            draft.browserAgentPasswordsEnabled.description,
            draft.browserAgentContactsEnabled.description,
            draft.browserAgentPaymentCardsEnabled.description,
            draft.browserDownloadDestinationRaw,
            draft.browserDownloadAskEveryTime.description,
            draft.browserCustomDownloadBookmark?.base64EncodedString() ?? "",
            draft.browserHistoryAccessRaw, draft.browserPresentationModeRaw,
            draft.browserPageAppearanceRaw, draft.browserJavaScriptPermissionRaw,
            draft.browserUserDownloadPermissionRaw, draft.browserAgentDownloadPermissionRaw,
            draft.browserUploadPermissionRaw, draft.browserPopupPermissionRaw,
            draft.browserExternalPermissionRaw, draft.browserCameraPermissionRaw,
            draft.browserMicrophonePermissionRaw,
            draft.walletSepoliaRPCURL,
            draft.walletAlphaEnabled.description,
            draft.walletBrowserProviderEnabled.description,
        ].joined(separator: "\u{1F}")
    }

    private func applyImmediateDraft() {
        var saved = model.settings
        saved.applyImmediatePreferences(from: draft)
        // Immediate preferences should feel live and quiet. In particular,
        // seeding the draft on appear must never close Settings or flash a
        // misleading “saved” confirmation before the user has interacted.
        model.applySettings(saved, showConfirmation: false)
    }

    private func isStagedPage(_ page: SettingsPage) -> Bool {
        guard page.mutationPolicy == .staged else { return false }
        if page == .accounts {
            return expandedAdvancedPages.contains(.accounts) || hasStagedChanges(for: page)
        }
        return true
    }

    private var currentPageHasStagedChanges: Bool {
        hasStagedChanges(for: model.settingsPage)
    }

    private var hasAnyStagedChanges: Bool {
        SettingsPage.allCases
            .filter { $0.mutationPolicy == .staged }
            .contains(where: hasStagedChanges)
    }

    private var stagedPageHasError: Bool {
        model.settingsPage == .network && proxyDraftError != nil
    }

    private func hasStagedChanges(for page: SettingsPage) -> Bool {
        switch page {
        case .network:
            var candidate = model.settings
            candidate.proxyModeRaw = draft.proxyModeRaw
            candidate.proxyTypeRaw = draft.proxyTypeRaw
            candidate.proxyHost = draft.proxyHost
            candidate.proxyBypass = draft.proxyBypass
            candidate.proxyUsername = proxyAuthEnabled ? draft.proxyUsername : ""
            candidate.proxyPort = AppSettings.clampProxyPort(
                Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            return candidate.proxyModeRaw != model.settings.proxyModeRaw
                || candidate.proxyTypeRaw != model.settings.proxyTypeRaw
                || candidate.proxyHost != model.settings.proxyHost
                || candidate.proxyPort != model.settings.proxyPort
                || candidate.proxyBypass != model.settings.proxyBypass
                || candidate.proxyUsername != model.settings.proxyUsername
                || !proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .developer:
            let steps = iterationLimit.trimmingCharacters(in: .whitespacesAndNewlines)
            return draft.backendURL != model.settings.backendURL
                || draft.backendRoot != model.settings.backendRoot
                || draft.terminalShell != model.settings.terminalShell
                || draft.terminalLoginShell != model.settings.terminalLoginShell
                || (steps.isEmpty ? nil : Int(steps)) != model.settings.maxIterations
        case .accounts:
            let window = localWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            return (window.isEmpty ? nil : Int(window)) != model.settings.localContextWindow
        default:
            return false
        }
    }

    private func applyStagedPage(_ page: SettingsPage) {
        var saved = model.settings
        var proxyCredentialChanged = false
        switch page {
        case .network:
            saved.proxyModeRaw = draft.proxyModeRaw
            saved.proxyTypeRaw = draft.proxyTypeRaw
            saved.proxyHost = draft.proxyHost
            saved.proxyBypass = draft.proxyBypass
            saved.proxyUsername = draft.proxyUsername
            applyProxyDraft(to: &saved)
            proxyCredentialChanged = updateProxyCredential(for: saved)
        case .developer:
            saved.backendURL = draft.backendURL
            saved.backendRoot = draft.backendRoot
            saved.terminalShell = draft.terminalShell
            saved.terminalLoginShell = draft.terminalLoginShell
            let steps = iterationLimit.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.maxIterations = steps.isEmpty ? nil : Int(steps)
        case .accounts:
            let window = localWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.localContextWindow = window.isEmpty ? nil : Int(window)
        default:
            return
        }
        model.applySettings(saved, proxyCredentialChanged: proxyCredentialChanged)
        if page == .network {
            proxyPassword = ""
            proxyPasswordStored = model.persistenceEnabled
                && CredentialStore.has(account: CredentialStore.proxyCredentialKey)
        }
    }

    private func discardStagedChanges(for page: SettingsPage) {
        switch page {
        case .network:
            draft.proxyModeRaw = model.settings.proxyModeRaw
            draft.proxyTypeRaw = model.settings.proxyTypeRaw
            draft.proxyHost = model.settings.proxyHost
            draft.proxyBypass = model.settings.proxyBypass
            draft.proxyUsername = model.settings.proxyUsername
            proxyPort = model.settings.proxyPort.map(String.init) ?? ""
            proxyAuthEnabled = !model.settings.proxyUsername.isEmpty
            proxyPassword = ""
        case .developer:
            draft.backendURL = model.settings.backendURL
            draft.backendRoot = model.settings.backendRoot
            draft.terminalShell = model.settings.terminalShell
            draft.terminalLoginShell = model.settings.terminalLoginShell
            iterationLimit = model.settings.maxIterations.map(String.init) ?? ""
        case .accounts:
            localWindow = model.settings.localContextWindow.map(String.init) ?? ""
        default:
            break
        }
    }

    private func discardAllStagedChanges() {
        SettingsPage.allCases
            .filter { $0.mutationPolicy == .staged }
            .forEach(discardStagedChanges)
    }

    private func requestSettingsDismissal() {
        applyImmediateDraft()
        if hasAnyStagedChanges {
            discardPromptPresented = true
        } else {
            completeSettingsDismissal()
        }
    }

    /// An updater relaunch is an explicit request to finish the session. Apply
    /// every valid staged page and close Settings; if the proxy draft is
    /// invalid, keep the window open so the relaunch cannot silently discard
    /// or persist malformed configuration.
    private func prepareSettingsForUpdate() -> Bool {
        applyImmediateDraft()
        if hasStagedChanges(for: .network), proxyDraftError != nil {
            model.settingsPage = .network
            model.showToast("Fix the invalid proxy settings before installing the update")
            return false
        }
        SettingsPage.allCases
            .filter { $0.mutationPolicy == .staged && hasStagedChanges(for: $0) }
            .forEach(applyStagedPage)
        completeSettingsDismissal()
        return true
    }

    private func completeSettingsDismissal() {
        model.clearAppearancePreview()
        switch presentationContext {
        case .sheet:
            dismiss()
        case .settingsWindow:
            dismissWindow()
        }
        model.settingsPresented = false
    }

    // MARK: - Pages

    private var generalPage: some View { appAndDeveloperPage }
    private var appearancePage: some View { appAndDeveloperPage }
    private var chatPage: some View { appAndDeveloperPage }
    private var developerPage: some View { appAndDeveloperPage }

    /// The four lightweight app pages share one native Form implementation.
    /// Keeping their controls here preserves every binding and identifier while
    /// the studio sidebar provides the new information architecture.
    private var appAndDeveloperPage: some View {
        Form {
            if model.settingsPage == .appearance {
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

                Text("Changes apply immediately. System follows your Mac automatically.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Section("Accent colour") {
                    HStack(spacing: 10) {
                        ForEach(LocusAccentPreset.allCases) { preset in
                            accentPresetButton(preset)
                        }
                    }

                    HStack(spacing: 12) {
                        ZStack {
                            Image(
                                nsImage: LocusBrandIcon.image(
                                    accent: draft.resolvedAccent.logoNSColor,
                                    size: 128
                                )
                            )
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 38, height: 38)
                            // Generated NSImages are otherwise free to retain
                            // their previous SwiftUI image node while dragging.
                            .id(draft.resolvedAccent)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current Locus logo, \(draft.resolvedAccent.title)")
                        .accessibilityIdentifier("settings.accentColor.preview")

                        ColorPicker(
                            "Choose any colour",
                            selection: customAccentColor,
                            supportsOpacity: false
                        )
                        .accessibilityIdentifier("settings.accentColor.custom")

                        if draft.accentPresetRaw == LocusAccentSelection.customRawValue {
                            Text("#\(draft.customAccentHex)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(LocusTheme.textTertiary)
                                .accessibilityLabel("Custom colour \(draft.customAccentHex)")
                        }
                    }

                    Text("Buttons, highlights, status accents, and in-app Locus marks update together. Your choice is saved automatically.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("settings.accentColor")

                Section("Workspace header") {
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
            }

            if model.settingsPage == .developer {
                Section("Agent") {
                TextField("Maximum tool steps per request — all models (optional)", text: $iterationLimit)
                    .accessibilityIdentifier("settings.maxIterations")

                Text("Leave empty for 40. This ceiling applies to local, ChatGPT-plan, and API-backed requests because Locus still coordinates their tool loop. A request that reaches the limit stops and says so.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .id("settings.maxIterations")
            }

            if model.settingsPage == .chat {
                Section("Conversation") {
                Picker("Store notes by", selection: $draft.notesScopeRaw) {
                    ForEach(NotesScope.allCases) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.notesScope")

                Text("Workspace notes are shared by every chat in the current project. Choose Each chat for separate scratchpads, or Everywhere for one document that every chat in every workspace opens. Switching scope leaves the other documents untouched, so you can move back and forth.")
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
                    "Team requests — Runs",
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
                .id("settings.notesScope")

                Section("Transcript") {
                    Picker("Reasoning", selection: $draft.thinkingVisibilityRaw) {
                        ForEach(ThinkingVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.thinkingVisibility")

                    Picker("Tool activity", selection: $draft.toolActivityVisibilityRaw) {
                        ForEach(ToolActivityVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.toolActivityVisibility")

                    Text("Collapsed reasoning uses inline summary disclosures, and adjacent tool calls use inline activity summaries where they occurred.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("settings.thinkingVisibility")

                Section("Voice") {
                    Toggle("Show dictation and voice controls", isOn: $draft.voiceControlsEnabled)
                        .accessibilityIdentifier("settings.voice.enabled")

                    if draft.voiceControlsEnabled {
                        Picker("Speech engine", selection: $draft.voiceSpeechEngineRaw) {
                            ForEach(VoiceSpeechEngine.allCases) { engine in
                                Text(engine.title).tag(engine.rawValue)
                            }
                        }
                        .accessibilityIdentifier("settings.voice.engine")

                        if draft.resolvedVoiceSpeechEngine == .openAICompatible {
                            Picker("Speech account", selection: $draft.voiceCloudAccountID) {
                                Text("Choose an account").tag(String?.none)
                                ForEach(model.eligibleVoiceAccounts) { account in
                                    Text(account.displayName).tag(Optional(account.id.uuidString))
                                }
                            }
                            .accessibilityIdentifier("settings.voice.account")

                            if model.eligibleVoiceAccounts.isEmpty {
                                HStack {
                                    Text("Add an OpenAI API or compatible custom account first.")
                                        .font(.locus(size: 9))
                                        .foregroundStyle(LocusTheme.warning)
                                    Spacer()
                                    Button("Open Providers") { model.settingsPage = .accounts }
                                }
                            }

                            TextField(
                                "Transcription model",
                                text: $draft.voiceCloudTranscriptionModel
                            )
                            .accessibilityIdentifier("settings.voice.transcriptionModel")
                            TextField("Speech model", text: $draft.voiceCloudSpeechModel)
                                .accessibilityIdentifier("settings.voice.speechModel")
                            TextField("Voice identifier", text: $draft.voiceCloudVoiceIdentifier)
                                .accessibilityIdentifier("settings.voice.voiceIdentifier")
                        }

                        Picker("Recognition language", selection: $draft.voiceLanguageIdentifier) {
                            Text("System language").tag("")
                            ForEach(voiceLanguageIdentifiers, id: \.self) { identifier in
                                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                                    .tag(identifier)
                            }
                        }
                        .accessibilityIdentifier("settings.voice.language")

                        if draft.resolvedVoiceSpeechEngine == .system {
                            Picker("Spoken voice", selection: $draft.voiceSystemVoiceIdentifier) {
                                Text("System voice").tag("")
                                ForEach(systemSpeechVoices, id: \.identifier) { voice in
                                    Text("\(voice.name) — \(voice.language)")
                                        .tag(voice.identifier)
                                }
                            }
                            .accessibilityIdentifier("settings.voice.systemVoice")

                            Toggle(
                                "Allow Apple online recognition when on-device speech is unavailable",
                                isOn: $draft.voiceAppleNetworkRecognitionAllowed
                            )
                            .accessibilityIdentifier("settings.voice.appleNetworkConsent")
                        }

                        Picker("After push-to-talk", selection: $draft.voiceSendBehaviorRaw) {
                            ForEach(VoiceSendBehavior.allCases) { behavior in
                                Text(behavior.title).tag(behavior.rawValue)
                            }
                        }
                        .accessibilityIdentifier("settings.voice.sendBehavior")

                        Button(
                            voiceControl.isCapabilityTesting
                                ? "Stop and Play Back" : "Test Voice"
                        ) {
                            voiceControl.startCapabilityTest()
                        }
                        .disabled(
                            draft.resolvedVoiceSpeechEngine == .openAICompatible
                                && draft.voiceCloudAccountID == nil
                        )
                        .accessibilityIdentifier("settings.voice.test")

                        if !voiceControl.capabilityTestMessage.isEmpty {
                            Text(voiceControl.capabilityTestMessage)
                                .font(.locus(size: 9, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted)
                                .accessibilityIdentifier("settings.voice.testResult")
                        }

                        Text(voicePrivacyExplanation)
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .id("settings.voice")
            }

            if model.settingsPage == .general {
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
                .id("settings.maximumActiveChats")

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
                .id("settings.launchAtLogin")

                CompanionAccessSettingsSection(enabled: $draft.mobileAccessEnabled)
                    .environmentObject(model)

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
            }

            if model.settingsPage == .developer {
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
                .id("settings.terminalShell")

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
                .id("settings.backendURL")

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
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.\(model.settingsPage.accessibilityKey).content")
    }

    private var voiceLanguageIdentifiers: [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .filter { !$0.isEmpty }
            .sorted {
                let lhs = Locale.current.localizedString(forIdentifier: $0) ?? $0
                let rhs = Locale.current.localizedString(forIdentifier: $1) ?? $1
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private var systemSpeechVoices: [AVSpeechSynthesisVoice] {
        let language = draft.voiceLanguageIdentifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { language.isEmpty || $0.language.hasPrefix(language.split(separator: "-").first.map(String.init) ?? language) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var voicePrivacyExplanation: String {
        if draft.resolvedVoiceSpeechEngine == .system {
            return draft.voiceAppleNetworkRecognitionAllowed
                ? "Recognition uses Apple Speech. On-device processing is preferred; Apple online recognition is allowed only because you enabled it. Recordings are limited to 60 seconds."
                : "Recognition and playback use macOS System Speech. Locus requires on-device recognition and will ask before allowing Apple online processing. Recordings are limited to 60 seconds."
        }
        return "Audio is sent only to the account selected above, using that account’s credentials and proxy route. Locus never falls back to cloud speech automatically and deletes temporary recordings after each request."
    }

    private func localModelRow(_ localModel: ModelInfo) -> some View {
        let hidden = model.isLocalModelHidden(localModel.name)
        let current = model.isCurrentRoute(account: nil, model: localModel.name)
        let details = [
            localModel.detail,
            localModel.size > 0 ? localModel.sizeLabel : "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")

        return HStack(spacing: 10) {
            ProviderLogo(name: "Ollama", size: 24)
                .opacity(hidden ? 0.48 : 1)

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
        BrowserSettingsView(
            browser: model.browser,
            draft: $draft,
            deepLink: $pendingSearchAnchor,
            advancedExpanded: advancedBinding(for: .browser)
        )
        .environmentObject(model)
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
                Text("This page edits the Default profile. Open Proxy Manager in the right inspector for named profiles, split routing, strict tunnel mode, pool health, and automatic failover.")
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
                    Task { await codexComponent.remove() }
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
#endif

    private var customAccentColor: Binding<Color> {
        Binding(
            get: { draft.resolvedAccent.fillColor },
            set: { color in
                guard let hex = LocusAccentSelection.hexString(for: NSColor(color)) else {
                    return
                }
                draft.customAccentHex = hex
                draft.accentPresetRaw = LocusAccentSelection.customRawValue
            }
        )
    }

    private func accentPresetButton(_ preset: LocusAccentPreset) -> some View {
        let selected = draft.accentPresetRaw == preset.rawValue
        let accent = LocusAccentSelection(
            rawValue: preset.rawValue,
            customHex: draft.customAccentHex
        )
        return Button {
            draft.accentPresetRaw = preset.rawValue
        } label: {
            VStack(spacing: 6) {
                Image(nsImage: LocusBrandIcon.image(accent: accent.logoNSColor, size: 128))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .id(accent)
                Text(preset.title)
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(selected ? LocusTheme.accentAction : LocusTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? LocusTheme.accentFill.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? LocusTheme.accentAction : LocusTheme.separator,
                        lineWidth: selected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) accent colour")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings.accentColor.\(preset.rawValue)")
    }

#if !LOCUS_APP_STORE
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
                if providerAccounts.providerAccounts.isEmpty {
                    Text("No accounts yet — Locus runs on local Ollama until you add one.")
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("settings.accounts.empty")
                }

                ForEach(providerAccounts.providerAccounts) { account in
                    HStack(spacing: 10) {
                        ProviderLogo(
                            kind: account.kind,
                            name: account.displayName,
                            url: account.resolvedBaseURL,
                            size: 28
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(
                                    providerAccounts.accountStatus[account.id]?.isHealthy ?? account.isCredentialReady
                                        ? LocusTheme.success
                                        : LocusTheme.coral
                                )
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(LocusTheme.surfaceCard, lineWidth: 1.5))
                                .accessibilityHidden(true)
                        }
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
                    // Menu flattens custom Label icons: monogram logos (A, K, …)
                    // replace the item title with invisible white text, so the
                    // dropdown stays text-only.
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
                HStack(spacing: 10) {
                    ProviderLogo(name: "Ollama", size: 26)
                    Text("Ollama models installed on this Mac appear automatically. No account is needed.")
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                }

                if providerAccounts.installedLocalModels.isEmpty {
                    Text(model.isModelOnline
                        ? "No local models are installed."
                        : "Connect to Ollama to see installed models.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                } else {
                    ForEach(providerAccounts.installedLocalModels) { localModel in
                        localModelRow(localModel)
                    }
                }

                HStack {
                    Button {
                        model.openModelLibraryFromSettings()
                        dismiss()
                    } label: {
                        Label {
                            Text("Browse Hugging Face Models…")
                        } icon: {
                            ProviderLogo(name: "Hugging Face", size: 20)
                        }
                    }
                    .accessibilityIdentifier("settings.accounts.browseHuggingFace")

                    Button("Refresh") {
                        Task { await model.refreshMetadata() }
                    }
                    .disabled(deletingLocalModelName != nil)
                    .accessibilityIdentifier("settings.localModels.refresh")
                }

            }

            Section {
                SettingsAdvancedDisclosureRow(
                    isExpanded: advancedBinding(for: .accounts),
                    detail: "Local model context and runtime tuning"
                )
                .accessibilityIdentifier("settings.accounts.advanced")
            }

            if expandedAdvancedPages.contains(.accounts) {
                Section("Advanced local model settings") {
                    TextField("Local context window in tokens (optional)", text: $localWindow)
                        .accessibilityIdentifier("settings.localContextWindow")

                    Text("Leave empty and Locus asks Ollama for the largest window the model was built for, up to 32,768 tokens — Ollama's own default is 4,096, most of which a turn spends on tools before the conversation starts. Bigger windows cost memory for the KV cache, and a model that ends up partly on the CPU is backed off automatically. Set a value to pin one exactly; it is requested as num_ctx and is what compaction budgets against.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.localContextDescription")
                }
                .id("settings.localContextWindow")
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

            Section("Application Context") {
                if ApplicationContextService.isAvailable {
                    Text("Appshots are explicit one-message captures. A live application attachment is granted separately for each task and restricts that task to the exact selected process, even when global Computer Control is enabled.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Accessibility text") {
                        permissionStatus(
                            granted: computerControl.accessibilityGranted,
                            grant: computerControl.requestAccessibility,
                            settings: computerControl.openAccessibilitySettings
                        )
                    }
                    LabeledContent("Window screenshots") {
                        permissionStatus(
                            granted: computerControl.screenRecordingGranted,
                            grant: computerControl.requestScreenRecording,
                            settings: computerControl.openScreenRecordingSettings
                        )
                    }
                    LabeledContent("Live task attachment") {
                        Text(model.currentLiveApplicationTarget?.name ?? "Not attached")
                            .foregroundStyle(model.currentLiveApplicationIsConnected
                                ? LocusTheme.success : LocusTheme.muted)
                    }
                } else {
                    Label("Unavailable in the Mac App Store build", systemImage: "lock.app.dashed")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Install the signed direct-download build to capture or attach another application.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                }
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
                            granted: computerControl.accessibilityGranted,
                            grant: computerControl.requestAccessibility,
                            settings: computerControl.openAccessibilitySettings
                        )
                    }
                    LabeledContent("Screen Recording") {
                        permissionStatus(
                            granted: computerControl.screenRecordingGranted,
                            grant: computerControl.requestScreenRecording,
                            settings: computerControl.openScreenRecordingSettings
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

            Section("iOS Simulator") {
                if SimulatorControlService.isSupportedBuild {
                    Toggle("Allow control of the attached simulator", isOn: Binding(
                        get: { model.settings.simulatorControlEnabled },
                        set: { model.setSimulatorControlEnabled($0) }
                    ))
                    .disabled(model.currentSimulatorTarget == nil)
                    .accessibilityIdentifier("settings.simulatorControl.enabled")

                    Text("Simulator access stays off until you explicitly attach a device and accept the consent prompt. Avoid real accounts and sensitive data; a hosted model may receive screenshots only after provider-specific session consent.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Xcode") {
                        settingsStatus(
                            ready: simulatorControl.helperHealth.xcodePath != nil,
                            readyText: "Ready",
                            missingText: "Full Xcode required"
                        )
                    }
                    LabeledContent("Signed bridge") {
                        settingsStatus(
                            ready: simulatorControl.helperHealth.touchHelperPresent
                                && simulatorControl.helperHealth.treeHelperPresent,
                            readyText: "Present",
                            missingText: "Missing"
                        )
                    }
                    LabeledContent("Bridge compatibility") {
                        settingsStatus(
                            ready: simulatorControl.nativeAvailable,
                            readyText: "Ready",
                            missingText: simulatorControl.helperHealth.message
                        )
                    }
                    LabeledContent("iOS runtime") {
                        settingsStatus(
                            ready: !simulatorControl.devices.isEmpty,
                            readyText: "\(simulatorControl.devices.count) devices",
                            missingText: "No installed runtime"
                        )
                    }
                    LabeledContent("Live streaming") {
                        settingsStatus(
                            ready: computerControl.screenRecordingGranted,
                            readyText: "Screen Recording granted",
                            missingText: "Screen Recording required"
                        )
                    }
                    LabeledContent("Keyboard controls") {
                        settingsStatus(
                            ready: computerControl.accessibilityGranted,
                            readyText: "Accessibility granted",
                            missingText: "Accessibility required"
                        )
                    }
                    LabeledContent("Attached device") {
                        Text(model.currentSimulatorTarget?.device.name ?? "Not attached")
                            .foregroundStyle(model.currentSimulatorTarget == nil
                                ? LocusTheme.muted : LocusTheme.success)
                    }
                    if model.currentSimulatorTarget == nil {
                        Text("Attach a simulator from the composer’s attachment menu.")
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    }
                } else {
                    Label("Unavailable in the Mac App Store build", systemImage: "lock.app.dashed")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("The direct-download build includes the signed Xcode Simulator bridge; the App Store package contains no bridge helper or simulator tool schema.")
                        .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            computerControl.refreshPermissionStatus()
            applicationContext.refreshRunningApplications()
            model.refreshSimulatorDevices()
        }
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

    private func settingsStatus(
        ready: Bool,
        readyText: String,
        missingText: String
    ) -> some View {
        Label(
            ready ? readyText : missingText,
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundStyle(ready ? LocusTheme.success : LocusTheme.warning)
        .font(.locus(size: 9, weight: .semibold))
    }

    private func accountDetail(_ account: ProviderAccount) -> String {
        let status = providerAccounts.accountStatus[account.id]
            ?? (account.hasKey ? .keySaved : .noKey)
        if account.kind == .chatGPT,
           let window = providerAccounts.chatGPTUsageByAccount[account.id]?.rateLimits.rateLimits?.primary
        {
            let reset = window.resetsAt.map {
                "resets " + Date(timeIntervalSince1970: Double($0))
                    .formatted(.relative(presentation: .named))
            }
            let activity = providerAccounts.chatGPTUsageByAccount[account.id]?
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
