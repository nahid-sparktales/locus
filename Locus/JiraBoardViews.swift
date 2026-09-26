import SwiftUI

struct JiraBoardSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: BoardStore
    @State private var serverID = ""
    @State private var sites: [JiraSite] = []
    @State private var siteID = ""
    @State private var jql = "assignee = currentUser() ORDER BY updated DESC"
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    private var client: JiraBoardClient { .init(backend: model.backend, workspace: store.workspacePath) }
    private var settingsKey: String { "jira.board." + NotesStore.digest(of: store.workspacePath) }
    private var servers: [ExtensionMCPServer] {
        extensionsModel.extensions.mcpServers.filter { URL(string: $0.url ?? "")?.host == "mcp.atlassian.com" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label { Text("Jira") } icon: { ProviderLogo(name: "Jira", size: 30) }
                    .font(.locus(size: 22, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.locus()).keyboardShortcut(.cancelAction)
            }
            Text("Bring Jira issues into this workspace. Assign agents here, then publish changes when you’re ready.")
                .font(.locus(size: 12)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
            if !servers.isEmpty {
                Picker("Account", selection: $serverID) {
                    Text("Choose a connection").tag("")
                    ForEach(servers) { Text($0.name).tag($0.id) }
                }.onChange(of: serverID) { _, _ in sites = []; siteID = "" }
            }
            HStack {
                Button(servers.isEmpty ? "Connect Atlassian" : "Sign in to Atlassian") { connect() }
                    .buttonStyle(.locus(.primary)).accessibilityIdentifier("jira.connect")
                if !serverID.isEmpty {
                    Button("Load sites") { perform { sites = try await client.sites(serverID: serverID); restoreSite() } }
                        .buttonStyle(.locus())
                }
            }
            if !sites.isEmpty {
                Picker("Jira site", selection: $siteID) { ForEach(sites) { Text($0.name).tag($0.id) } }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Issues to sync (JQL)").font(.locus(size: 12, weight: .semibold))
                    TextField("project = MYPROJECT ORDER BY updated DESC", text: $jql)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("jira.filter")
                    Text("For example: project = MYPROJECT. Existing cards stay on the board when they leave this filter.")
                        .font(.locus(size: 11)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
                }
                Button("Sync issues to board") { sync() }.buttonStyle(.locus(.primary))
                    .disabled(siteID.isEmpty || jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("jira.sync")
            }
            if busy { ProgressView("Connecting to Jira…").controlSize(.small) }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(colors.signalDeep) }
            if let error { Text(error).foregroundStyle(colors.warning).textSelection(.enabled) }
            Text("Jira Cloud · Sign-in uses your Atlassian permissions. Sync reads issues; publishing and status changes are separate actions on each card.")
                .font(.locus(size: 11)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
        }
        .font(.locus(size: 12)).padding(24).frame(width: 550)
        .foregroundStyle(colors.ink).background(colors.panel).disabled(busy).interactiveDismissDisabled(busy)
        .task {
            await extensionsModel.refreshExtensions()
            let saved = UserDefaults.standard.dictionary(forKey: settingsKey)
            serverID = saved?["server"] as? String ?? servers.first?.id ?? ""
            jql = saved?["jql"] as? String ?? jql
            if !serverID.isEmpty { perform { sites = try await client.sites(serverID: serverID); restoreSite() } }
        }
    }

    private func restoreSite() {
        let saved = UserDefaults.standard.dictionary(forKey: settingsKey)?["site"] as? String
        siteID = sites.first(where: { $0.id == saved })?.id ?? sites.first?.id ?? ""
    }

    private func connect() {
        perform {
            let server: ExtensionMCPServer
            if let existing = servers.first(where: { $0.id == serverID }) {
                server = try await model.backend.post("/api/extensions/mcp/enable", body: [
                    "id": existing.id, "enabled": true, "scope": "workspace", "workspace": store.workspacePath,
                ], as: ExtensionMCPServer.self)
            } else {
                server = try await model.backend.post("/api/extensions/mcp", body: [
                    "name": "Atlassian", "url": "https://mcp.atlassian.com/v2/mcp?tools=all",
                    "transport": "streamable_http", "auth": "oauth", "enabled": true,
                    "enabled_global": false, "enabled_workspaces": [store.workspacePath],
                ], as: ExtensionMCPServer.self)
            }
            await extensionsModel.refreshExtensions()
            serverID = server.id
            let signedIn = await withCheckedContinuation { continuation in
                extensionsModel.authenticateMCPServer(server) { continuation.resume(returning: $0) }
            }
            guard signedIn else { throw JiraBoardError.message(extensionsModel.extensionErrorMessage ?? "Atlassian sign-in was cancelled.") }
            sites = try await client.sites(serverID: server.id); restoreSite()
        }
    }

    private func sync() {
        guard let site = sites.first(where: { $0.id == siteID }) else { return }
        perform {
            let issues = try await client.search(serverID: serverID, site: site, jql: jql)
            try store.importJira(issues)
            UserDefaults.standard.set(["server": serverID, "site": siteID, "jql": jql], forKey: settingsKey)
            notice = "Synced \(issues.count) issue\(issues.count == 1 ? "" : "s"). Open a card to assign an agent."
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct JiraCardPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locusViewColors) private var colors
    @ObservedObject var store: BoardStore
    let cardID: UUID
    var beforeAction: (() -> Bool)? = nil
    var hasPendingEdits = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var transitions: [JiraTransition] = []
    @State private var publishing = false
    private var card: BoardCard? { store.cards.first { $0.id == cardID } }
    private var client: JiraBoardClient { .init(backend: model.backend, workspace: store.workspacePath) }

    var body: some View {
        if let card, let link = card.jira {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(link.key, systemImage: "arrow.triangle.2.circlepath").font(.locus(size: 12, weight: .semibold))
                    Text(link.status).font(.locus(size: 11)).foregroundStyle(colors.muted)
                    Spacer()
                    if let url = link.url { Link("Open in Jira", destination: url).font(.locus(size: 11)) }
                }
                HStack {
                    Button("Pull latest") { perform { try store.importJira([try await client.fetch(link)]) } }.buttonStyle(.locus())
                    Button("Publish changes") { if beforeAction?() ?? true { publishing = true } }.buttonStyle(.locus(.primary))
                        .disabled(!hasPendingEdits && card.title == link.remoteTitle && card.details == link.remoteDetails)
                    if transitions.isEmpty {
                        Button("Change Jira status…") { perform { transitions = try await client.transitions(link)
                            if transitions.isEmpty { notice = "No status changes are available for this issue." } } }.buttonStyle(.locus())
                    } else {
                        Menu("Jira status") {
                            ForEach(transitions) { option in
                                Button(option.name) { perform {
                                    try store.importJira([try await client.transition(link, id: option.id)])
                                    transitions = []; notice = "Jira status updated."
                                } }
                            }
                        }.menuStyle(.borderlessButton)
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(colors.warning).textSelection(.enabled) }
                if let notice { Text(notice).foregroundStyle(colors.muted) }
            }.font(.locus(size: 11)).padding(12)
                .background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 12)).disabled(busy)
                .confirmationDialog("Publish changes to \(link.key)?", isPresented: $publishing, titleVisibility: .visible) {
                    Button("Publish to Jira") { perform {
                        guard let current = self.card else { throw JiraBoardError.message("This card was removed.") }
                        let remote = try await client.publish(current)
                        try store.importJira([remote]); notice = "Changes published to Jira."
                    } }
                    Button("Cancel", role: .cancel) { }
                } message: { Text("Updates the Jira title and any edited description. An edited description is published as plain text; other Jira fields are preserved.") }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, beforeAction?() ?? true else { return }; busy = true; error = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
