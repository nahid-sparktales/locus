import SwiftUI

/// Native disclosure arrows have a small hit target on macOS. Keep the header
/// as a keyboard-accessible button whose entire row opens the section.
private struct SavedAgentDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var inset: CGFloat = 0
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(inset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides this section")
            .accessibilityIdentifier(identifier)

            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
            }
        }
    }
}

/// Shared editing controls for the overview and the unsaved profile draft.
/// Linking a project stores its location; it does not move or copy that project.
struct AgentWorkspacePreferencesEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locusOceanTheme) private var ocean
    @Binding var profile: AgentProfile
    var compact = false
    @State private var showingDetails = false
    @State private var showingProjects = false

    private var selectedPath: String {
        profile.workspacePreferences?.defaultProjectPath ?? model.savedAgentHomePath(profile)
    }

    private var detailColor: Color {
        ocean ? Color(nsColor: LocusTheme.oceanPalette.inkSoft) : LocusTheme.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("New chats start in", systemImage: "folder")
                    .font(.locus(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Menu {
                    ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                        Button { select(choice.path) } label: {
                            if choice.path == selectedPath { Label(choice.title, systemImage: "checkmark") }
                            else { Text(choice.title) }
                        }.help(choice.path)
                    }
                    Divider()
                    Button("Add project…") { chooseProject() }
                } label: {
                    Label(model.savedAgentWorkspaceTitle(profile, path: selectedPath),
                          systemImage: selectedPath == model.savedAgentHomePath(profile) ? "house" : "folder")
                        .lineLimit(1).truncationMode(.middle)
                }.accessibilityIdentifier("savedAgent.defaultWorkspace")
            }
            if compact {
                Text(selectedPath == model.savedAgentHomePath(profile)
                     ? "A personal home, with a separate folder for each new chat."
                     : "New chats use this project. Existing chats keep their folders.")
                    .font(.locus(size: 12)).foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("Add project…") { chooseProject() }.accessibilityIdentifier("savedAgent.linkProject")
                Button("Open home") {
                    model.revealSavedAgentWorkspace(profile, path: model.savedAgentHomePath(profile))
                }.accessibilityIdentifier("savedAgent.openHome")
            }.buttonStyle(.bordered)
            if compact {
                DisclosureGroup("Folder details & linked projects", isExpanded: $showingDetails) {
                    folderDetails.padding(.top, 8)
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.folderDetails.toggle"))
                .font(.locus(size: 12))
            } else {
                folderDetails
            }
        }
    }

    private var folderDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedPath).font(.locus(size: 11)).foregroundStyle(detailColor)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Home chats get their own task folders. Git projects use separate working copies; other project folders are shared.")
                .font(.locus(size: 12)).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
            Text("Changes apply to new chats. Existing chats and automations keep their folders.")
                .font(.locus(size: 11)).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
            if let paths = profile.workspacePreferences?.projectPaths, !paths.isEmpty {
                DisclosureGroup("Linked projects · \(paths.count)", isExpanded: $showingProjects) {
                    ForEach(paths, id: \.self) { path in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.locus(size: 12, weight: .medium))
                                Text(path).font(.locus(size: 11)).foregroundStyle(detailColor)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Unlink") { unlink(path) }
                                .buttonStyle(.locus(.quiet)).help("Unlink project; files and existing chats are kept")
                                .accessibilityLabel("Unlink \(URL(fileURLWithPath: path).lastPathComponent)")
                        }.padding(.top, 8)
                    }
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.linkedProjects.toggle"))
                .font(.locus(size: 12))
            }
        }
    }

    private func chooseProject() {
        if let path = model.chooseSavedAgentProjectFolder() { select(path) }
    }
    private func select(_ path: String) {
        if path != model.savedAgentHomePath(profile) {
            do { try model.prepareSavedAgentWorkspace(profile, workspace: path) }
            catch { model.showToast(error.localizedDescription); return }
        }
        var preferences = profile.workspacePreferences ?? AgentWorkspacePreferences()
        preferences.defaultProjectPath = path == model.savedAgentHomePath(profile) ? nil : path
        if preferences.defaultProjectPath != nil { preferences.projectPaths.append(path) }
        preferences.normalize()
        profile.workspacePreferences = preferences
    }
    private func unlink(_ path: String) {
        var preferences = profile.workspacePreferences ?? AgentWorkspacePreferences()
        preferences.projectPaths.removeAll { $0 == path }
        if preferences.defaultProjectPath == path { preferences.defaultProjectPath = nil }
        profile.workspacePreferences = preferences
    }
}

/// Shared by the main workspace, inspector and world. Supplied conversation
/// callbacks preserve the world's project and selected resident.
struct SavedAgentInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    var workspace: String? = nil
    var newChat: (() -> Void)? = nil
    var openChat: ((SessionSummary) -> Void)? = nil
    var newChatDisabled: Bool? = nil
    var inspectActivity: ((AgentInspectorContext) -> Void)? = nil

    var body: some View {
        SavedAgentOverviewContent(initialProfile: profile, workspace: workspace, newChat: newChat,
            openChat: openChat, newChatDisabled: newChatDisabled, inspectActivity: inspectActivity,
            automation: model.eventAutomations)
    }
}

private struct SavedAgentOverviewContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var accounts: ProviderAccountsModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @Environment(\.locusOceanTheme) private var ocean
    let initialProfile: AgentProfile
    let workspace: String?
    let newChat: (() -> Void)?
    let openChat: ((SessionSummary) -> Void)?
    let newChatDisabled: Bool?
    let inspectActivity: ((AgentInspectorContext) -> Void)?
    @ObservedObject var automation: EventAutomationModel
    @State private var refreshing = false
    @State private var showAllChats = false
    @State private var showInstructions = false
    @State private var showTaskFolders = false
    @State private var accountToReview: ProviderAccount?
    @State private var recoveryPresented = false
    @State private var resultTranscript: SavedAgentOverviewSnapshot.ResultTranscript?
    @State private var resultLoading = false
    @State private var resultError: String?
    @State private var activeResultRequest: ResultRequest?

    private var profile: AgentProfile {
        agentTeams.agentProfiles.first { $0.id == initialProfile.id } ?? initialProfile
    }

    private struct ResultRequest: Hashable {
        let profileID: UUID
        let sessionID: String
        let modifiedAt: Double
        let runID: String?
    }

    private var overview: SavedAgentOverviewSnapshot {
        SavedAgentOverviewSnapshot.resolve(profile: profile,
            sessions: sessionCatalog.snapshot.sessions, definitions: model.agentDefinitions,
            connections: automation.connections, deliveries: automation.deliveries,
            occurrences: schedule.occurrencesBySchedule.values.flatMap { $0 },
            runs: activity.activityRuns, accounts: accounts.providerAccounts,
            readyAccountIDs: Set(accounts.accountStatus.compactMap { id, state in state.isHealthy ? id : nil }),
            accountModels: accounts.accountModels, accountStatuses: accounts.accountStatus,
            localModels: accounts.localModels.map(\.name),
            runningSessionIDs: model.runningChatSessionIDs,
            attentionSessionIDs: [], attentionItems: activity.attentionItems, workspace: workspace,
            resultTranscript: resultTranscript)
    }
    private var resultRequest: ResultRequest? {
        guard let id = overview.resultSessionID,
              let session = sessionCatalog.snapshot.sessionsByID[id],
              session.savedAgentProfileID == profile.id else { return nil }
        var modified = session.mtime
        for run in activity.activityRuns where run.sessionID == id { modified = max(modified, run.updatedAt) }
        for delivery in automation.deliveries where delivery.conversationSessionID == id { modified = max(modified, delivery.updatedAt) }
        for occurrences in schedule.occurrencesBySchedule.values {
            for occurrence in occurrences where occurrence.sessionID == id { modified = max(modified, occurrence.updatedAt) }
        }
        return ResultRequest(profileID: profile.id, sessionID: id, modifiedAt: modified, runID: overview.latestResult?.runID)
    }
    private var ink: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.ink) : LocusTheme.ink }
    private var secondary: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.inkSoft) : LocusTheme.inkSoft }
    private var muted: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.muted) : LocusTheme.muted }
    private var accent: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.signalDeep) : LocusTheme.accentAction }
    private var canvas: Color { ocean ? Color(nsColor: LocusTheme.oceanPalette.paper) : LocusTheme.surfaceCanvas }

    var body: some View {
        let snapshot = overview
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    readiness(snapshot)
                    if let error = automation.lastError ?? schedule.lastLoadError {
                        Label("Some information couldn’t be refreshed. \(error)", systemImage: "arrow.clockwise.circle")
                            .font(.locus(size: 12)).foregroundStyle(LocusTheme.warning).textSelection(.enabled)
                    }
                    workspaceSection
                    if geometry.size.width >= 740 {
                        HStack(alignment: .top, spacing: 16) {
                            connectionHealth(snapshot).frame(maxWidth: .infinity, alignment: .topLeading)
                            latestResult(snapshot).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        connectionHealth(snapshot)
                        latestResult(snapshot)
                    }
                    automations(snapshot)
                    chats(snapshot)
                    instructions
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(geometry.size.width >= 740 ? 30 : 18)
                .frame(maxWidth: .infinity, alignment: .top)
            }.background(canvas)
        }
        .foregroundStyle(ink)
        .accessibilityIdentifier("savedAgent.overview")
        .task(id: profile.id) {
            guard model.persistenceEnabled, !model.isUITesting else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await refresh()
            }
        }
        .sheet(item: $accountToReview) { account in
            AccountEditorView(account: account, isNew: false)
                .appFeatureEnvironment(from: model)
        }
        .sheet(isPresented: $recoveryPresented) {
            ActivityCenterView()
                .appFeatureEnvironment(from: model)
                .frame(width: 500, height: 650)
        }
        .onChange(of: activity.activityCenterPresented) {
            if !activity.activityCenterPresented { recoveryPresented = false }
        }
        .task(id: resultRequest) {
            guard model.persistenceEnabled, !model.isUITesting else { return }
            guard let request = resultRequest else { resultLoading = false; activeResultRequest = nil; return }
            await loadResult(request)
        }
        .onChange(of: profile.id) {
            showAllChats = false; showInstructions = false
            resultTranscript = nil; resultError = nil; resultLoading = false; activeResultRequest = nil
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.locus(size: 23, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.locus(size: 25, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(profile.role.title).font(.locus(size: 13)).foregroundStyle(muted)
                }
                Spacer(minLength: 8)
                Button { Task { await refresh(refreshAccounts: true) } } label: {
                    if refreshing { ProgressView().controlSize(.small).frame(width: 24, height: 24) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                }
                .buttonStyle(.locus(.icon)).disabled(refreshing)
                .help("Refresh this agent’s status").accessibilityLabel("Refresh agent status")
                .accessibilityIdentifier("savedAgent.refresh")
            }
                    ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { primaryActions }
                VStack(alignment: .leading, spacing: 10) { primaryActions }
            }
        }
    }

    @ViewBuilder private var primaryActions: some View {
        Button { startChat() } label: { Label("New chat", systemImage: "plus.bubble") }
            .buttonStyle(.borderedProminent).tint(accent)
            .disabled(newChatDisabled ?? (model.chatNavigationDisabled || model.creatingSavedAgentChatIDs.contains(profile.id)))
            .accessibilityIdentifier("savedAgent.newChat")
        if newChat == nil {
            Menu {
                ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                    Button(choice.title) { model.newSavedAgentChat(profile, workspace: choice.path) }
                        .help(choice.path)
                }
                Divider()
                Button("Choose another project…") {
                    if let path = model.chooseSavedAgentProjectFolder() {
                        model.newSavedAgentChat(profile, workspace: path)
                    }
                }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.chatNavigationDisabled || model.creatingSavedAgentChatIDs.contains(profile.id))
            .help("Choose a workspace for this new chat")
            .accessibilityLabel("New chat in workspace")
            .accessibilityIdentifier("savedAgent.newChatWorkspace")
        }
        Button { model.presentSavedAgentEditor(profile) } label: { Label("Edit agent", systemImage: "slider.horizontal.3") }
            .buttonStyle(.bordered).accessibilityIdentifier("savedAgent.edit")
    }

    private var workspaceSection: some View {
        card {
            if let workspace {
                sectionTitle("Working in", symbol: "folder")
                Text(model.savedAgentWorkspaceTitle(profile, path: workspace))
                    .font(.locus(size: 14, weight: .medium))
                Text(workspace).font(.locus(size: 11)).foregroundStyle(secondary).textSelection(.enabled)
                Text("New chats and automations opened from this map use this project.")
                    .font(.locus(size: 12)).foregroundStyle(secondary)
            } else {
                AgentWorkspacePreferencesEditor(profile: Binding(
                    get: { agentTeams.agentProfiles.first { $0.id == profile.id } ?? profile },
                    set: { agentTeams.saveAgentProfile($0) }), compact: true)
            }
            if let chat = currentWorkspaceChat,
               let root = chat.workspacePath {
                Divider()
                let execution = chat.executionPath ?? chat.cwd ?? root
                DisclosureGroup(isExpanded: $showTaskFolders) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(execution).font(.locus(size: 11)).foregroundStyle(muted).textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button("Open task folder") { NSWorkspace.shared.open(URL(fileURLWithPath: execution)) }
                                .disabled(!FileManager.default.fileExists(atPath: execution))
                            if let output = chat.environment?["output_directory"] {
                                Button("Open outputs") { NSWorkspace.shared.open(URL(fileURLWithPath: output)) }
                                    .disabled(!FileManager.default.fileExists(atPath: output))
                            }
                        }.buttonStyle(.bordered)
                    }.padding(.top, 8)
                } label: {
                    Text("\(chat.id == model.currentSessionID ? "This chat" : "Latest chat"): \(model.savedAgentWorkspaceTitle(profile, path: root))")
                        .font(.locus(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.taskFolders.toggle"))
            }
        }.accessibilityIdentifier("savedAgent.workspaces")
    }

    private var currentWorkspaceChat: SessionSummary? {
        let owned = model.savedAgentChats(profile.id).filter { chat in workspace.map(chat.belongsToWorkspace) ?? true }
        if model.savedAgentOverviewProfile == nil,
           let current = owned.first(where: { $0.id == model.currentSessionID }) { return current }
        return owned.first
    }

    private func readiness(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: readinessSymbol(snapshot))
                    .font(.locus(size: 18, weight: .medium))
                    .foregroundStyle(readinessColor(snapshot))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.statusTitle).font(.locus(size: 16, weight: .semibold))
                    Text(snapshot.detail).font(.locus(size: 13)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(snapshot.issues) { issue in
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(issue.title).font(.locus(size: 13, weight: .semibold))
                    Text(issue.detail).font(.locus(size: 12)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let action = issue.action {
                        Button(actionTitle(action)) { perform(action) }.buttonStyle(.bordered)
                            .accessibilityIdentifier("savedAgent.recovery.\(issue.id)")
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background((snapshot.needsAttention ? LocusTheme.warning : accent).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke((snapshot.needsAttention ? LocusTheme.warning : accent).opacity(0.22), lineWidth: 1))
        .accessibilityIdentifier("savedAgent.readiness")
    }

    private func connectionHealth(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            sectionTitle("Connection health", symbol: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.route.title).font(.locus(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: snapshot.route.issue != nil ? "exclamationmark.circle.fill" :
                            snapshot.route.isVerified ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(snapshot.route.issue != nil ? LocusTheme.warning :
                                            snapshot.route.isVerified ? LocusTheme.success : muted)
                        .accessibilityHidden(true)
                }
                Text(snapshot.route.model).font(.locus(size: 12)).foregroundStyle(secondary).textSelection(.enabled)
                Text(snapshot.route.issue ?? snapshot.route.detail)
                    .font(.locus(size: 12)).foregroundStyle(snapshot.route.issue == nil ? muted : LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button(snapshot.route.accountID == nil ? "Review local model" : "Review account") {
                    reviewAccount(snapshot.route.accountID)
                }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
            }
            if !snapshot.connections.isEmpty {
                Divider()
                ForEach(snapshot.connections) { connection in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: connection.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(connection.isHealthy ? LocusTheme.success : LocusTheme.warning)
                            .frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.title).font(.locus(size: 13, weight: .medium))
                            Text(connection.detail).font(.locus(size: 12)).foregroundStyle(secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Button("Review connections") { reviewConnections() }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
            } else {
                Text("No event sources are used by this agent yet.")
                    .font(.locus(size: 12)).foregroundStyle(muted)
            }
        }.accessibilityIdentifier("savedAgent.connections")
    }

    private func latestResult(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            sectionTitle("Latest result", symbol: "text.bubble")
            if resultLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading saved response…").font(.locus(size: 12)).foregroundStyle(muted)
                }
            }
            if let result = snapshot.latestResult {
                stateBadge(result.statusTitle, warning: result.needsAttention, busy: result.isInProgress)
                Text(result.title).font(.locus(size: 14, weight: .semibold)).lineLimit(2)
                Text(result.summary).font(.locus(size: 13)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(6).textSelection(.enabled)
                Text(result.timestamp, style: .relative).font(.locus(size: 12)).foregroundStyle(muted)
                if let action = result.action {
                    Button(actionTitle(action)) { perform(action) }.buttonStyle(.bordered)
                        .accessibilityIdentifier("savedAgent.latestResult.open")
                }
            } else {
                Text("Your next result will appear here.").font(.locus(size: 14, weight: .medium))
                Text("Start a conversation or add automatic work. You’ll see its outcome and any next steps here.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resultError {
                Text(resultError).font(.locus(size: 12)).foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if let request = resultRequest {
                    Button("Try again") { Task { await loadResult(request) } }
                        .buttonStyle(.bordered).disabled(resultLoading)
                }
            }
        }.accessibilityIdentifier("savedAgent.latestResult")
    }

    private func automations(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            HStack {
                sectionTitle("Automations", symbol: "bolt")
                Spacer(minLength: 8)
                Button { addAutomation() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bordered).accessibilityLabel("Add automation")
                    .accessibilityIdentifier("savedAgent.addAutomation")
            }
            if snapshot.automations.isEmpty {
                Text("Choose what starts this agent.").font(.locus(size: 14, weight: .medium))
                Text("Set a schedule, respond to an incoming event, or watch a price.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
            } else {
                ForEach(Array(snapshot.automations.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 3) }
                    automationRow(item)
                }
            }
            Label("Automatic work runs on this Mac while Locus is open.", systemImage: "desktopcomputer")
                .font(.locus(size: 12)).foregroundStyle(muted).padding(.top, 4)
        }.accessibilityIdentifier("savedAgent.automations")
    }

    private func automationRow(_ item: SavedAgentOverviewSnapshot.Automation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.definition.isSchedule ? "calendar.badge.clock" : "bolt")
                    .foregroundStyle(accent).frame(width: 20, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.definition.name).font(.locus(size: 14, weight: .semibold))
                    Text(item.definition.kindTitle).font(.locus(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 8)
                stateBadge(item.statusTitle, warning: item.needsAttention, busy: item.isBusy)
            }
            Text(item.detail).font(.locus(size: 13)).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = item.nextRunAt {
                Label { Text("Next · \(next.formatted(date: .abbreviated, time: .shortened))") } icon: { Image(systemName: "clock") }
                    .font(.locus(size: 12)).foregroundStyle(muted)
            }
            if let latest = item.latestActivity {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Last · \(latest.statusTitle)").font(.locus(size: 12, weight: .medium))
                        .foregroundStyle(latest.needsAttention ? LocusTheme.warning : secondary)
                    Text(Date(timeIntervalSince1970: latest.timestamp), style: .relative)
                        .font(.locus(size: 12)).foregroundStyle(muted)
                }
                if let error = latest.error, !error.isEmpty {
                    Text(error).font(.locus(size: 12)).foregroundStyle(secondary).lineLimit(3).textSelection(.enabled)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { automationActions(item) }
                VStack(alignment: .leading, spacing: 10) { automationActions(item) }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("savedAgent.automation.\(item.id)")
    }

    @ViewBuilder private func automationActions(_ item: SavedAgentOverviewSnapshot.Automation) -> some View {
        Button(item.needsAttention ? "Review setup" : "Edit") { model.editAgent(item.definition) }
            .buttonStyle(.bordered)
        if !item.enabled {
            Button("Resume") { model.setAgentEnabled(item.definition, enabled: true) }
                .buttonStyle(.bordered).disabled(model.isChangingAgentEnabled(item.definition))
                .help("Resume future automatic starts; this does not retry past work")
                .accessibilityIdentifier("savedAgent.automation.\(item.id).resume")
        }
        if let latest = item.latestActivity {
            Button("View activity") { inspect(latest.context) }
                .buttonStyle(.locus()).foregroundStyle(accent)
        }
        if item.enabled {
            Menu {
                Button("Pause automatic starts") { model.setAgentEnabled(item.definition, enabled: false) }
                    .disabled(model.isChangingAgentEnabled(item.definition))
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions for \(item.definition.name)")
        }
    }

    private func chats(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            sectionTitle(workspace == nil ? "Chats" : "Chats in this project", symbol: "bubble.left.and.bubble.right")
            if snapshot.chats.isEmpty {
                Text("No conversations yet.").font(.locus(size: 13)).foregroundStyle(muted)
            } else {
                ForEach(showAllChats ? snapshot.chats : Array(snapshot.chats.prefix(4))) { session in
                    Button { open(session) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: session.isAgentEventChat ? "bolt" : "bubble.left")
                                .foregroundStyle(muted).frame(width: 20, height: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayTitle).font(.locus(size: 13, weight: .medium))
                                    .foregroundStyle(ink).lineLimit(1)
                                Text(session.isAgentEventChat ? "Receives automatic work" : "Conversation")
                                    .font(.locus(size: 12)).foregroundStyle(muted)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.locus(size: 11, weight: .medium)).foregroundStyle(muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus()).disabled(model.chatNavigationDisabled && openChat == nil)
                    .accessibilityIdentifier("savedAgent.chat.\(session.id)")
                }
                if snapshot.chats.count > 4 {
                    Button(showAllChats ? "Show recent chats" : "Show all \(snapshot.chats.count) chats") { showAllChats.toggle() }
                        .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
                }
            }
        }
    }

    private var instructions: some View {
        card(padding: 0) {
            DisclosureGroup(isExpanded: $showInstructions) {
                Text(profile.instructions.isEmpty ? "No additional instructions." : profile.instructions)
                    .font(.locus(size: 13)).foregroundStyle(secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("savedAgent.instructions.content")
            } label: { sectionTitle("Instructions", symbol: "text.alignleft") }
            .disclosureGroupStyle(SavedAgentDisclosureStyle(inset: 18, identifier: "savedAgent.instructions.toggle"))
            .accessibilityIdentifier("savedAgent.instructions")
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.locus(size: 14, weight: .semibold)).foregroundStyle(ink)
    }
    private func card<Content: View>(padding: CGFloat = 18, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .locusSurface(.floating, radius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LocusTheme.line.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false).accessibilityHidden(true))
    }
    private func stateBadge(_ title: String, warning: Bool, busy: Bool) -> some View {
        Text(title).font(.locus(size: 11, weight: .medium))
            .foregroundStyle(warning ? LocusTheme.warning : busy ? accent : secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((warning ? LocusTheme.warning : busy ? accent : muted).opacity(0.08), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
    private func readinessSymbol(_ snapshot: SavedAgentOverviewSnapshot) -> String {
        if snapshot.needsAttention { return "exclamationmark.circle.fill" }
        if snapshot.isBusy { return "circle.dotted" }
        if snapshot.status == .unverified { return "questionmark.circle" }
        if snapshot.status == .paused { return "pause.circle" }
        return "checkmark.circle.fill"
    }
    private func readinessColor(_ snapshot: SavedAgentOverviewSnapshot) -> Color {
        if snapshot.needsAttention { return LocusTheme.warning }
        if snapshot.isBusy { return accent }
        if snapshot.status == .unverified || snapshot.status == .paused { return muted }
        return LocusTheme.success
    }
    private func startChat() { if let newChat { newChat() } else { model.newSavedAgentChat(profile) } }
    private func open(_ session: SessionSummary) {
        if let openChat { openChat(session); return }
        guard !model.chatNavigationDisabled else {
            model.showToast("Finish the current conversation change before opening another chat.")
            return
        }
        model.resume(session)
    }
    private func addAutomation() {
        model.manageSavedAgent(profile, workspace: workspace)
        model.configureAgentPendingCreation = true
    }
    private func reviewConnections() {
        model.manageSavedAgent(profile, workspace: workspace)
        model.configureAgentTab = .sources
    }
    private func inspect(_ context: AgentInspectorContext) {
        if let inspectActivity { inspectActivity(context); return }
        model.agentInspector.show(context)
        model.selectInspectorTab(.agent)
    }
    private func reviewAccount(_ id: UUID?) {
        if let id, let account = accounts.providerAccounts.first(where: { $0.id == id }) {
            accountToReview = account
        } else {
            model.presentSavedAgentEditor(profile)
        }
    }
    private func actionTitle(_ action: SavedAgentOverviewSnapshot.Action) -> String {
        switch action {
        case .editAgent: "Review agent settings"
        case .manageAccount: "Review account"
        case .connections: "Review connections"
        case .automation: "Review automation"
        case .activity: "Review activity"
        case .attention: "Review recovery"
        case .chat: "Open chat"
        }
    }
    private func perform(_ action: SavedAgentOverviewSnapshot.Action) {
        switch action {
        case .editAgent: model.presentSavedAgentEditor(profile)
        case .manageAccount(let id): reviewAccount(id)
        case .connections: reviewConnections()
        case .automation(let reference):
            if let definition = model.inspectorAgentDefinition(reference) { model.editAgent(definition) }
        case .activity(let context): inspect(context)
        case .attention(let focus):
            activity.openActivityCenter(focus: focus)
            if inspectActivity != nil { recoveryPresented = true }
        case .chat(let id):
            if let session = sessionCatalog.snapshot.sessionsByID[id] { open(session) }
            else { model.showToast("This chat is no longer available. Its saved activity is still shown here.") }
        }
    }

    @MainActor private func refresh(refreshAccounts: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let catalog: Void = accounts.refreshAccountCatalogs(force: refreshAccounts)
        async let events: Void = automation.refresh(announceFailure: false)
        async let schedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
        async let runs: Void = activity.refreshActivityRuns(announceFailure: false)
        _ = await (catalog, events, schedules, runs)
        for task in overview.automations.compactMap({ $0.definition.schedule }) {
            guard !Task.isCancelled else { return }
            await schedule.refreshOccurrences(for: task, announceFailure: false)
        }
    }

    @MainActor private func loadResult(_ request: ResultRequest) async {
        guard activeResultRequest != request else { return }
        activeResultRequest = request
        resultLoading = true
        resultError = nil
        defer {
            if activeResultRequest == request { resultLoading = false; activeResultRequest = nil }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard let segment = request.sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        do {
            let response = try await model.backend.get("/api/sessions/\(segment)",
                as: SavedAgentOverviewSnapshot.ResultTranscript.self)
            guard !Task.isCancelled, resultRequest == request, profile.id == request.profileID else { return }
            // The pure projection also verifies response ownership and the exact
            // run before it uses a final assistant answer as this agent's result.
            resultTranscript = response
        } catch {
            guard !Task.isCancelled, resultRequest == request else { return }
            resultError = "The saved response couldn’t be loaded. Open its activity for details."
        }
    }
}
