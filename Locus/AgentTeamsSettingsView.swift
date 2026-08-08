import SwiftUI

struct AgentTeamsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingProfile: AgentProfile?
    @State private var editingTeam: AgentTeam?
    @State private var consentAccount: ProviderAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader
                runtimeSection
                profilesSection
                teamsSection
                routingConsentSection
            }
            .padding(20)
        }
        .sheet(item: $editingProfile) { profile in
            AgentProfileEditor(profile: profile) {
                model.saveAgentProfile($0)
                editingProfile = nil
            }
            .environmentObject(model)
        }
        .sheet(item: $editingTeam) { team in
            AgentTeamEditor(team: team) {
                model.saveAgentTeam($0)
                editingTeam = nil
            }
            .environmentObject(model)
        }
        .confirmationDialog(
            "Allow automatic hosted routing?",
            isPresented: Binding(
                get: { consentAccount != nil },
                set: { if !$0 { consentAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let account = consentAccount {
                Button("Allow \(account.displayName)") {
                    model.grantAutomaticRoutingConsent(for: account.id)
                    consentAccount = nil
                }
            }
            Button("Cancel", role: .cancel) { consentAccount = nil }
        } message: {
            Text("A dispatcher may send the task and specialist evidence to this provider without asking again during a team run. API keys stay in memory and are never stored in team manifests.")
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLOBAL SCHEDULER")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Stepper(
                "Up to \(model.globalAgentConcurrency) simultaneous model calls",
                value: $model.globalAgentConcurrency,
                in: 1...8
            )
            .font(.system(size: 10, weight: .semibold))
            Text("Shared fairly across running chats. Expired worker leases are reclaimed after a crash.")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(12)
        .locusCard()
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Agents & Teams")
                .font(.system(size: 16, weight: .bold))
            Text("Create explicit model roles, then combine them into a dispatcher-led team with one writer.")
                .font(.system(size: 10))
                .foregroundStyle(LocusTheme.muted)
        }
    }

    private var profilesSection: some View {
        settingsSection(title: "AGENT PROFILES", actionTitle: "Add Agent") {
            let role = nextSuggestedRole
            editingProfile = AgentProfile(
                name: role.title,
                model: model.selectedModel,
                role: role,
                instructions: role.defaultInstructions,
                accessCeiling: role == .implementer ? .workspaceWrite : .readOnly
            )
        } content: {
            if model.agentProfiles.isEmpty {
                emptyRow("No agent profiles yet. Start with a Dispatcher and Implementer.")
            } else {
                ForEach(model.agentProfiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.accessCeiling.canWrite ? "hammer.fill" : "eye.fill")
                            .foregroundStyle(profile.accessCeiling.canWrite ? LocusTheme.signalDeep : LocusTheme.muted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.system(size: 11, weight: .semibold))
                            Text("\(profile.role.title) · \(routeTitle(profile.route)) · \(profile.model)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingProfile = profile }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { model.removeAgentProfile(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }

    private var teamsSection: some View {
        settingsSection(title: "TEAMS", actionTitle: "Add Team") {
            let dispatcher = model.agentProfiles.first(where: { $0.role == .dispatcher })
            let writer = model.agentProfiles.first(where: { $0.accessCeiling.canWrite })
            let members = Array(Set([dispatcher?.id, writer?.id].compactMap { $0 }))
            editingTeam = AgentTeam(
                name: "New Team",
                dispatcherID: dispatcher?.id,
                fallbackDispatcherID: nil,
                memberIDs: members,
                defaultWriterID: writer?.id
            )
        } content: {
            if model.agentTeams.isEmpty {
                emptyRow("Teams are explicit: add a dispatcher, one writer, and any read-only specialists.")
            } else {
                ForEach(model.agentTeams) { team in
                    let errors = AgentTeamValidation.errors(team: team, profiles: model.agentProfiles)
                    HStack(spacing: 10) {
                        Image(systemName: errors.isEmpty ? "person.3.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(errors.isEmpty ? LocusTheme.signalDeep : LocusTheme.coral)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.name).font(.system(size: 11, weight: .semibold))
                            Text(errors.first ?? "\(team.memberIDs.count) members · \(team.budget.maxConcurrentCalls) concurrent calls · \(team.budget.maxModelCalls) calls max")
                                .font(.system(size: 8))
                                .foregroundStyle(errors.isEmpty ? LocusTheme.muted : LocusTheme.coral)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editingTeam = team }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) { model.removeAgentTeam(team) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }

    private var routingConsentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTOMATIC HOSTED ROUTING")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Text("Locus asks once per account before a dispatcher may route team data to it automatically.")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
            ForEach(model.providerAccounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName).font(.system(size: 10, weight: .semibold))
                        Text(account.resolvedBaseURL).font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    if model.teamRoutingConsentAccountIDs.contains(account.id) {
                        Button("Revoke") { model.revokeAutomaticRoutingConsent(for: account.id) }
                            .buttonStyle(.borderless)
                    } else {
                        Button("Allow…") { consentAccount = account }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var nextSuggestedRole: AgentRole {
        AgentRole.allCases.first { role in !model.agentProfiles.contains(where: { $0.role == role }) }
            ?? .generalist
    }

    private func routeTitle(_ route: AgentRoute) -> String {
        switch route {
        case .localOllama: "Local Ollama"
        case .providerAccount(let id):
            model.providerAccounts.first(where: { $0.id == id })?.displayName ?? "Unavailable account"
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(LocusTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
    }

    private func settingsSection<Content: View>(
        title: String,
        actionTitle: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Button(actionTitle, systemImage: "plus", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(LocusTheme.white.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        }
    }
}

private struct AgentProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentProfile
    @State private var tags: String
    @State private var connectionResult: String?
    @State private var testingConnection = false
    let onSave: (AgentProfile) -> Void

    init(profile: AgentProfile, onSave: @escaping (AgentProfile) -> Void) {
        _draft = State(initialValue: profile)
        _tags = State(initialValue: profile.capabilityTags.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            Picker("Role", selection: $draft.role) {
                ForEach(AgentRole.allCases) { Text($0.title).tag($0) }
            }
            Picker("Provider route", selection: $draft.route) {
                Text("Local Ollama").tag(AgentRoute.localOllama)
                ForEach(model.providerAccounts) { account in
                    Text(account.displayName).tag(AgentRoute.providerAccount(account.id))
                }
            }
            TextField("Exact model", text: $draft.model)
            Picker("Access ceiling", selection: $draft.accessCeiling) {
                ForEach(AgentAccessCeiling.allCases) { Text($0.title).tag($0) }
            }
            Picker("Classification", selection: $draft.metering) {
                ForEach(AgentMetering.allCases) { Text($0.title).tag($0) }
            }
            TextField("Capability tags", text: $tags, prompt: Text("code, tests, research"))
            Stepper("Timeout: \(draft.timeoutSeconds)s", value: $draft.timeoutSeconds, in: 30...3_600, step: 30)
            Stepper("Token limit: \(draft.tokenLimit.formatted())", value: $draft.tokenLimit, in: 1_024...1_000_000, step: 1_024)
            if draft.metering == .metered {
                TextField("Input $ / 1M tokens", value: $draft.inputCostPerMillion, format: .number)
                TextField("Output $ / 1M tokens", value: $draft.outputCostPerMillion, format: .number)
            }
            Text("Role instructions").font(.caption).foregroundStyle(LocusTheme.muted)
            TextEditor(text: $draft.instructions).frame(minHeight: 130)
            if let connectionResult {
                Text(connectionResult)
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }
            HStack {
                Button("Use \(draft.role.title) Template") {
                    draft.instructions = draft.role.defaultInstructions
                }
                Button(testingConnection ? "Testing…" : "Test Connection") {
                    testingConnection = true
                    Task {
                        connectionResult = await model.testAgentProfileConnection(draft)
                        testingConnection = false
                    }
                }
                .disabled(testingConnection || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.capabilityTags = tags.split(separator: ",").map(String.init)
                    draft.clamp()
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
            }
        }
        .padding(20)
        .frame(width: 560, height: 590)
    }
}

private struct AgentTeamEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentTeam
    let onSave: (AgentTeam) -> Void

    init(team: AgentTeam, onSave: @escaping (AgentTeam) -> Void) {
        _draft = State(initialValue: team)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Team name", text: $draft.name)
            Section("Members") {
                ForEach(model.agentProfiles) { profile in
                    Toggle(isOn: Binding(
                        get: { draft.memberIDs.contains(profile.id) },
                        set: { included in
                            if included { draft.memberIDs.append(profile.id) }
                            else { draft.memberIDs.removeAll { $0 == profile.id } }
                        }
                    )) {
                        Text("\(profile.name) · \(profile.role.title)")
                    }
                }
            }
            Picker("Dispatcher", selection: $draft.dispatcherID) {
                Text("Choose…").tag(nil as UUID?)
                ForEach(memberProfiles.filter { $0.role == .dispatcher }) {
                    Text($0.name).tag($0.id as UUID?)
                }
            }
            Picker("Fallback dispatcher", selection: $draft.fallbackDispatcherID) {
                Text("None").tag(nil as UUID?)
                ForEach(memberProfiles.filter { $0.role == .dispatcher }) {
                    Text($0.name).tag($0.id as UUID?)
                }
            }
            Picker("Default writer", selection: $draft.defaultWriterID) {
                Text("Choose…").tag(nil as UUID?)
                ForEach(memberProfiles.filter { $0.accessCeiling.canWrite }) {
                    Text($0.name).tag($0.id as UUID?)
                }
            }
            Toggle("Use isolated managed worktree for new Git tasks", isOn: $draft.useManagedWorktree)
            Section("Hard budgets") {
                Stepper("Delegated jobs: \(draft.budget.maxJobs)", value: $draft.budget.maxJobs, in: 1...16)
                Stepper("Orchestration rounds: \(draft.budget.maxRounds)", value: $draft.budget.maxRounds, in: 1...8)
                Stepper("Model calls: \(draft.budget.maxModelCalls)", value: $draft.budget.maxModelCalls, in: 1...48)
                Stepper("Concurrent calls: \(draft.budget.maxConcurrentCalls)", value: $draft.budget.maxConcurrentCalls, in: 1...8)
                Stepper("Metered tokens: \(draft.budget.maxMeteredTokens.formatted())", value: $draft.budget.maxMeteredTokens, in: 1_000...2_000_000, step: 10_000)
            }
            let errors = AgentTeamValidation.errors(team: draft, profiles: model.agentProfiles)
            if !errors.isEmpty {
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(LocusTheme.coral)
                        .font(.system(size: 9))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 650)
    }

    private var memberProfiles: [AgentProfile] {
        model.agentProfiles.filter { draft.memberIDs.contains($0.id) }
    }
}
