import AppKit
import SwiftUI

struct ChatGPTDirectoryApp: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let logoURL: String?
    let installURL: String?
    let accessible: Bool
    let enabled: Bool
    let callable: Bool?
    enum CodingKeys: String, CodingKey {
        case id, name, description, accessible, enabled, callable
        case logoURL = "logo_url"
        case installURL = "install_url"
    }
    var connectionURL: URL? {
        guard let installURL, let url = URL(string: installURL), url.scheme == "https",
              url.host == "chatgpt.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}

struct ChatGPTDirectoryResponse: Decodable {
    let apps: [ChatGPTDirectoryApp]
    let status: String
    let message: String
}

/// One searchable catalog; installation and account connection are distinct actions.
struct IntegrationBrowserView: View {
    @Environment(\.locusViewColors) private var colors
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @EnvironmentObject private var accounts: ProviderAccountsModel
    let reviewPlugin: (ExtensionCatalogEntry) -> Void
    let connectPreset: (ExtensionMCPPreset) -> Void
    let manageConnections: () -> Void

    private enum Source: String, CaseIterable, Identifiable {
        case all = "All", direct = "Direct connections", locus = "Locus plugins", chatGPT = "ChatGPT apps"
        var id: String { rawValue }
    }
    @State private var source: Source = .all
    @State private var query = ""
    @State private var accountID = ""
    @State private var addSource = false
    @State private var sourceURL = ""
    @State private var pendingApps: Set<String> = []
    private var chatGPTAccounts: [ProviderAccount] { accounts.providerAccounts.filter { $0.kind == .chatGPT } }
    private func matches(_ text: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.localizedCaseInsensitiveContains(query)
    }
    private var presets: [ExtensionMCPPreset] { extensionsModel.extensions.mcpPresets.filter { matches($0.displayName + " " + $0.description) } }
    private var plugins: [ExtensionCatalogEntry] { extensionsModel.extensionCatalog.filter { matches(($0.displayName ?? $0.name) + " " + ($0.description ?? "")) } }
    private var apps: [ChatGPTDirectoryApp] { extensionsModel.chatGPTApps.filter { matches($0.name + " " + $0.description) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Give your agents more to work with").font(.locus(size: 16, weight: .semibold))
                    Text("Connect your accounts or install a workflow. You control what each agent can access.")
                        .font(.locus(size: 10)).foregroundStyle(colors.muted)
                }
                Spacer()
                Button { addSource.toggle() } label: { Label("Add source", systemImage: "plus") }
                    .buttonStyle(.locus())
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                TextField("Search apps, connections and plugins", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("integrations.search")
                Picker("Show", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 190)
            }.padding(10).locusCard(radius: 9)
            if addSource {
                HStack {
                    TextField("Local folder, owner/repo, or HTTPS Git URL", text: $sourceURL).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let value = sourceURL
                        Task { await extensionsModel.addMarketplace(source: value); sourceURL = ""; addSource = false }
                    }.disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if source == .all || source == .direct {
                        section("Direct connections", detail: "Available to compatible agents across providers")
                        ForEach(presets) { preset in
                            row {
                                MCPLogo(name: preset.displayName, url: preset.url, presetID: preset.id, size: 34)
                            } content: {
                                title(preset.displayName, description: preset.description)
                                Text(preset.id == "google-drive" ? "Read-only · Google sign-in" : preset.id == "slack" ? "Requires an approved Slack app" : "Uses your account permissions")
                                    .font(.locus(size: 8)).foregroundStyle(colors.muted)
                            } action: {
                                Button(preset.installed ? "Manage" : "Connect") {
                                    if preset.installed { manageConnections() } else { connectPreset(preset) }
                                }.buttonStyle(.locus()).disabled(model.isBusy)
                            }
                        }
                    }
                    if source == .all || source == .locus {
                        section("Locus plugins", detail: "Installed on this Mac · skills, tools and workspaces")
                        ForEach(plugins) { entry in
                            row {
                                PluginLogo(name: entry.name, displayName: entry.displayName, iconData: entry.iconData)
                            } content: {
                                title(entry.displayName ?? entry.name, description: entry.description ?? "")
                                Text(entry.error ?? (entry.installed ? "Installed · \(entry.installedVersion ?? "local")" : "From \(entry.marketplaceID)"))
                                    .font(.locus(size: 8)).foregroundStyle(entry.error == nil ? colors.muted : colors.coral)
                            } action: {
                                Button(entry.installed ? "Review update" : "Install") { reviewPlugin(entry) }
                                    .buttonStyle(.locus()).disabled(!entry.available || model.isBusy)
                            }
                        }
                        if plugins.isEmpty { empty("No matching plugins. Add a marketplace source to discover more.") }
                    }
                    if source == .all || source == .chatGPT {
                        section("ChatGPT apps", detail: "For ChatGPT workspace agents · each action asks for approval")
                        if chatGPTAccounts.isEmpty {
                            empty("Add a ChatGPT account in Manage Accounts to browse its available apps.")
                        } else {
                            HStack {
                                Picker("Account", selection: $accountID) {
                                    ForEach(chatGPTAccounts) { account in
                                        Text(account.name).tag(account.codexHomeIdentifier)
                                    }
                                }.frame(maxWidth: 260)
                                Spacer()
                                Button("Refresh") { Task { await extensionsModel.refreshChatGPTApps(accountID: accountID, force: true) } }
                                    .disabled(extensionsModel.isLoadingChatGPTApps)
                            }
                            Text("Connect opens ChatGPT’s account connection page. Return here and refresh. Apps enabled here are available in Work chats with unrestricted tool access; use direct connections for agents with narrower permissions.")
                                .font(.locus(size: 9)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
                            if extensionsModel.isLoadingChatGPTApps { ProgressView("Loading available apps…").padding() }
                            if !extensionsModel.chatGPTAppsMessage.isEmpty { empty(extensionsModel.chatGPTAppsMessage) }
                            ForEach(apps) { app in
                                row {
                                    AsyncImage(url: URL(string: app.logoURL ?? "")) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        MCPLogo(name: app.name, url: "", size: 34)
                                    }.frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
                                } content: {
                                    title(app.name, description: app.description)
                                    Text(app.enabled ? (app.callable == false ? "Enabled · connection needs attention" : "Enabled for ChatGPT") : app.accessible ? "Connected to this account" : "ChatGPT connection required")
                                        .font(.locus(size: 8)).foregroundStyle(colors.muted)
                                } action: {
                                    if app.accessible {
                                        Button(app.enabled ? "Disable" : "Enable") {
                                            let selectedAccount = accountID
                                            pendingApps.insert(app.id)
                                            Task {
                                                await extensionsModel.setChatGPTApp(app, enabled: !app.enabled, accountID: selectedAccount)
                                                pendingApps.remove(app.id)
                                            }
                                        }.buttonStyle(.locus()).disabled(model.isBusy || pendingApps.contains(app.id))
                                    } else if let url = app.connectionURL {
                                        Link("Connect ↗", destination: url).buttonStyle(.locus())
                                    } else {
                                        Text("Unavailable for this account").font(.locus(size: 8)).foregroundStyle(colors.muted)
                                    }
                                }
                            }
                            if apps.isEmpty && !extensionsModel.isLoadingChatGPTApps && extensionsModel.chatGPTAppsMessage.isEmpty {
                                empty("No matching apps are available for this account.")
                            }
                        }
                    }
                }.padding(.bottom, 16)
            }
        }.padding(.horizontal, 14)
        .task {
            accountID = chatGPTAccounts.first?.codexHomeIdentifier ?? ""
        }
        .onChange(of: accountID) { Task { await extensionsModel.refreshChatGPTApps(accountID: accountID) } }
    }

    private func section(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.locus(size: 12, weight: .semibold))
            Text(detail).font(.locus(size: 9)).foregroundStyle(colors.muted)
        }.padding(.top, 8)
    }
    private func title(_ name: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.locus(size: 11, weight: .semibold))
            if !description.isEmpty { Text(description).font(.locus(size: 9)).foregroundStyle(colors.muted).lineLimit(2) }
        }
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.locus(size: 10)).foregroundStyle(colors.muted).padding(14).frame(maxWidth: .infinity, alignment: .leading).locusCard(radius: 9)
    }
    private func row<Icon: View, Content: View, Action: View>(@ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 4) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            action()
        }.padding(12).locusCard(radius: 10)
    }
}
