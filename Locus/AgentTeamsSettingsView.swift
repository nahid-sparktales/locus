import SwiftUI

struct AgentTeamsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingProfile: AgentProfile?
    @State private var editingTeam: AgentTeam?
    @State private var editingSuite: EvaluationSuite?
    @State private var evaluationReport: EvaluationReport?
    @State private var consentAccount: ProviderAccount?
    @State private var otlpAuthorization = CredentialStore.get(
        account: CredentialStore.otlpAuthorizationKey
    ) ?? ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader
                runtimeSection
                profilesSection
                teamsSection
                evaluationsSection
                observabilitySection
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
        .sheet(item: $evaluationReport) { report in
            EvaluationReportView(report: report)
        }
        .sheet(item: $editingSuite) { suite in
            EvaluationSuiteEditor(suite: suite) {
                model.saveEvaluationSuite($0)
                editingSuite = nil
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
                defaultWriterID: writer?.id,
                dispatchApprovalMode: .automatic,
                routingMode: .scorecard,
                routingWeights: .init()
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

    private var observabilitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("OPTIONAL TELEMETRY")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Toggle("Export completed team runs with OTLP/HTTP", isOn: $model.settings.otlpExportEnabled)
            TextField("https://collector.example/v1/traces", text: $model.settings.otlpEndpoint)
                .textFieldStyle(.roundedBorder)
            SecureField("Authorization header (optional)", text: $otlpAuthorization)
                .textFieldStyle(.roundedBorder)
            Toggle("Include visible conversation and tool content", isOn: $model.settings.otlpIncludeContent)
            Text("Metadata export is off by default. Content has a separate opt-in; credentials remain in Locus’s local credential store.")
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
            HStack {
                Spacer()
                Button("Save Authorization") {
                    model.saveOTLPAuthorization(otlpAuthorization)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .locusCard()
    }

    private var evaluationsSection: some View {
        settingsSection(title: "EVALUATION LAB", actionTitle: "Add Suite") {
            model.createEvaluationSuite()
        } content: {
            HStack {
                Text("Local, reproducible suites")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Button("Import JSON") { model.importEvaluationSuite() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.vertical, 7)
            Divider()
            if model.evaluationSuites.isEmpty {
                emptyRow("Reusable local cases compare team quality, reliability, latency, tokens, and cost without touching the source workspace.")
            } else {
                ForEach(model.evaluationSuites) { suite in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(LocusTheme.signalDeep)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suite.name).font(.system(size: 10, weight: .semibold))
                            Text("\(suite.cases.count) cases · disposable checkouts")
                                .font(.system(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Spacer()
                        Button("Run") { model.runEvaluationSuite(suite) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(
                                model.isBusy
                                    || (suite.cases.contains { $0.target == "team" }
                                        && model.selectedAgentTeam == nil)
                            )
                        Button("Edit") { editingSuite = suite }.buttonStyle(.borderless)
                        Button("Results") {
                            Task { evaluationReport = await model.loadEvaluationReport(suite) }
                        }
                        .buttonStyle(.borderless)
                        Button { model.exportEvaluationSuite(suite) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) { model.deleteEvaluationSuite(suite) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
            if let status = model.evaluationStatus {
                Label(status, systemImage: model.activeEvaluationID == nil ? "checkmark.circle" : "progress.indicator")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.vertical, 6)
            }
        }
        .task { await model.refreshEvaluations() }
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

private struct EvaluationReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: EvaluationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.suite.name).font(.system(size: 16, weight: .bold))
                    Text("Evaluation results")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack(spacing: 18) {
                metric("Pass rate", "\(Int(report.summary.passRate * 100))%")
                metric("Median", "\(report.summary.medianLatencyMilliseconds) ms")
                metric("p95", "\(report.summary.p95LatencyMilliseconds) ms")
                metric("Calls", report.summary.modelCalls.formatted())
                metric("Tokens", (report.summary.promptTokens + report.summary.completionTokens).formatted())
            }
            if !report.comparison.isEmpty {
                Text("COMPARISON")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(LocusTheme.muted)
                ForEach(report.comparison) { comparison in
                    HStack {
                        Text(comparison.configuration).font(.system(size: 9, weight: .semibold))
                        Spacer()
                        Text("\(Int(comparison.passRate * 100))% pass")
                        Text("p95 \(comparison.p95LatencyMilliseconds) ms")
                        Text("\(comparison.modelCalls) calls")
                        Text("\(comparison.retries) retries")
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .padding(9)
                    .locusCard()
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(report.results) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: result.state == "passed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.state == "passed" ? LocusTheme.success : LocusTheme.coral)
                                Text(result.caseID).font(.system(size: 9, weight: .semibold))
                                Spacer()
                                Text("\(result.durationMilliseconds ?? 0) ms")
                                    .font(.system(size: 7, design: .monospaced))
                            }
                            if let score = result.rubricScore {
                                Text("Subjective judge · \(Int(score))/100")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            if let error = result.error, !error.isEmpty {
                                Text(error).font(.system(size: 8)).foregroundStyle(LocusTheme.coral)
                            }
                        }
                        .padding(9)
                        .locusCard()
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 720, height: 620)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(title).font(.system(size: 7)).foregroundStyle(LocusTheme.muted)
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
    @State private var mcpTools: String
    @State private var mcpResources: String
    @State private var mcpPrompts: String
    let onSave: (AgentProfile) -> Void

    init(profile: AgentProfile, onSave: @escaping (AgentProfile) -> Void) {
        _draft = State(initialValue: profile)
        _tags = State(initialValue: profile.capabilityTags.joined(separator: ", "))
        _mcpTools = State(initialValue: (profile.mcpPolicy?.tools ?? []).joined(separator: ", "))
        _mcpResources = State(initialValue: (profile.mcpPolicy?.resources ?? []).joined(separator: ", "))
        _mcpPrompts = State(initialValue: (profile.mcpPolicy?.prompts ?? []).joined(separator: ", "))
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
            LabeledContent("Model") {
                HStack(spacing: 7) {
                    if modelChoices.isEmpty {
                        TextField("Exact model ID", text: $draft.model)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("agent.model.manual")
                    } else {
                        Picker("Model", selection: $draft.model) {
                            if modelSelectionUnavailable {
                                Text("\(draft.model) — unavailable")
                                    .tag(draft.model)
                            }
                            Text("Choose a model…").tag("")
                            ForEach(modelChoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("agent.model.picker")
                    }
                    Button {
                        Task { await refreshModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh models from this provider")
                    .accessibilityLabel("Refresh provider models")
                    .accessibilityIdentifier("agent.model.refresh")
                }
            }
            if modelSelectionUnavailable {
                Label(
                    "This provider does not report \(draft.model). Choose a model from the menu before saving.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.coral)
            } else if modelChoices.isEmpty {
                Text("This provider cannot list models, so enter its exact API model ID.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            } else {
                Text("Only models reported by the selected provider are shown.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
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
            Section("MCP access · none by default") {
                ForEach(model.extensions.mcpServers) { server in
                    Toggle(server.name, isOn: Binding(
                        get: { draft.mcpPolicy?.serverIDs.contains(server.id) == true },
                        set: { enabled in
                            var policy = draft.mcpPolicy ?? MCPAgentPolicy()
                            if enabled { policy.serverIDs.append(server.id) }
                            else { policy.serverIDs.removeAll { $0 == server.id } }
                            draft.mcpPolicy = policy
                        }
                    ))
                }
                TextField("Allowed tools", text: $mcpTools, prompt: Text("tool names, comma separated"))
                TextField("Allowed resources", text: $mcpResources, prompt: Text("resource URIs or names"))
                TextField("Allowed prompts", text: $mcpPrompts, prompt: Text("prompt names"))
                Text("Prompts introduce instructions and must be named explicitly. Mutating MCP tools remain writer-only.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
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
                    var policy = draft.mcpPolicy ?? MCPAgentPolicy()
                    policy.tools = csv(mcpTools)
                    policy.resources = csv(mcpResources)
                    policy.prompts = csv(mcpPrompts)
                    draft.mcpPolicy = policy
                    draft.clamp()
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(
                    draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || modelSelectionUnavailable
                )
            }
        }
        .padding(20)
        .frame(width: 600, height: 720)
        .task { await refreshModels() }
        .onChange(of: draft.route) { _, _ in
            draft.model = ""
            connectionResult = nil
            Task { await refreshModels() }
        }
    }

    private var modelChoices: [String] {
        let values: [String]
        switch draft.route {
        case .localOllama:
            values = model.localModels.map(\.name)
        case .providerAccount(let id):
            guard let account = model.providerAccounts.first(where: { $0.id == id }) else {
                return []
            }
            if account.kind.listsModels,
               let reported = model.accountModels[id],
               !reported.isEmpty
            {
                values = reported
            } else {
                values = [account.preferredModel] + account.kind.curatedModels
            }
        }
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seen.insert(trimmed.lowercased()).inserted
        }
    }

    private var modelSelectionUnavailable: Bool {
        !draft.model.isEmpty && !modelChoices.isEmpty && !modelChoices.contains(where: {
            $0.caseInsensitiveCompare(draft.model) == .orderedSame
        })
    }

    private func refreshModels() async {
        switch draft.route {
        case .localOllama:
            await model.refreshMetadata()
        case .providerAccount:
            await model.refreshAccountCatalogs(force: true)
        }
    }

    private func csv(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

private struct AgentTeamEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentTeam
    @State private var evaluationTags: String
    let onSave: (AgentTeam) -> Void

    init(team: AgentTeam, onSave: @escaping (AgentTeam) -> Void) {
        var value = team
        value.dispatchApprovalMode = value.resolvedDispatchApprovalMode
        value.routingMode = value.resolvedRoutingMode
        value.routingWeights = value.resolvedRoutingWeights
        _draft = State(initialValue: value)
        _evaluationTags = State(initialValue: (team.evaluationTags ?? []).joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        let errors = AgentTeamValidation.errors(team: draft, profiles: model.agentProfiles)
        VStack(spacing: 0) {
            ScrollView {
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
                    Section("Dispatch and routing") {
                        Picker("Plan approval", selection: Binding(
                            get: { draft.resolvedDispatchApprovalMode },
                            set: { draft.dispatchApprovalMode = $0 }
                        )) {
                            ForEach(DispatchApprovalMode.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Specialist routing", selection: Binding(
                            get: { draft.resolvedRoutingMode },
                            set: { draft.routingMode = $0 }
                        )) {
                            ForEach(AgentRoutingMode.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("Evaluation tags", text: $evaluationTags, prompt: Text("swift, security, tests"))
                        TextField(
                            "Maximum estimated cost",
                            value: $draft.maximumEstimatedCost,
                            format: .currency(code: "USD")
                        )
                        if draft.resolvedRoutingMode == .scorecard {
                            scoreWeight("Quality", \.quality)
                            scoreWeight("Reliability", \.reliability)
                            scoreWeight("Privacy/locality", \.privacy)
                            scoreWeight("Latency", \.latency)
                            scoreWeight("Cost", \.cost)
                            Text("Weights are normalized to 100% when saved. Limited data is shown until five comparable evaluations exist.")
                                .font(.system(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    Section("Hard budgets") {
                        Stepper("Delegated jobs: \(draft.budget.maxJobs)", value: $draft.budget.maxJobs, in: 1...16)
                        Stepper("Orchestration rounds: \(draft.budget.maxRounds)", value: $draft.budget.maxRounds, in: 1...8)
                        Stepper("Model calls: \(draft.budget.maxModelCalls)", value: $draft.budget.maxModelCalls, in: 1...48)
                        Stepper("Concurrent calls: \(draft.budget.maxConcurrentCalls)", value: $draft.budget.maxConcurrentCalls, in: 1...8)
                        Stepper("Metered tokens: \(draft.budget.maxMeteredTokens.formatted())", value: $draft.budget.maxMeteredTokens, in: 1_000...2_000_000, step: 10_000)
                    }
                    if !errors.isEmpty {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(LocusTheme.coral)
                                .font(.system(size: 9))
                        }
                    }
                }
                .padding(20)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("teamEditor.scroll")

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("teamEditor.cancel")
                Button("Save") {
                    draft.evaluationTags = evaluationTags.split(separator: ",").map(String.init)
                    draft.clamp()
                    onSave(draft)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!errors.isEmpty)
                    .accessibilityIdentifier("teamEditor.save")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LocusTheme.paper)
        }
        .frame(width: 620, height: 680)
    }

    private var memberProfiles: [AgentProfile] {
        model.agentProfiles.filter { draft.memberIDs.contains($0.id) }
    }

    private func scoreWeight(
        _ title: String,
        _ keyPath: WritableKeyPath<AgentScoreWeights, Double>
    ) -> some View {
        let binding = Binding<Double>(
            get: { draft.resolvedRoutingWeights[keyPath: keyPath] },
            set: { value in
                var weights = draft.resolvedRoutingWeights
                weights[keyPath: keyPath] = value
                draft.routingWeights = weights
            }
        )
        return HStack {
            Text(title)
            Slider(value: binding, in: 0...1, step: 0.05)
            Text(binding.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct EvaluationSuiteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var draft: EvaluationSuite
    @State private var tags: String
    let onSave: (EvaluationSuite) -> Void

    init(suite: EvaluationSuite, onSave: @escaping (EvaluationSuite) -> Void) {
        _draft = State(initialValue: suite)
        _tags = State(initialValue: suite.tags.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Suite name", text: $draft.name)
            TextField("Description", text: $draft.description, axis: .vertical)
            TextField("Tags", text: $tags, prompt: Text("swift, security, routing"))
            Toggle("Allow explicitly read-only MCP evidence", isOn: $draft.readOnlyMCP)
            Text("Coding cases always run in disposable managed worktrees. Computer control and mutating MCP tools are disabled.")
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
            Section("Cases") {
                ForEach(draft.cases.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("Case name", text: $draft.cases[index].name)
                            Button(role: .destructive) {
                                if draft.cases.count > 1 { draft.cases.remove(at: index) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .disabled(draft.cases.count == 1)
                        }
                        TextField("Prompt", text: $draft.cases[index].prompt, axis: .vertical)
                            .lineLimit(3...8)
                        TextField(
                            "Case tags",
                            text: caseTagsBinding(index),
                            prompt: Text("swift, routing, regression")
                        )
                        HStack {
                            Picker("Mode", selection: $draft.cases[index].mode) {
                                Text("Coding").tag("write")
                                Text("Read only").tag("read_only")
                            }
                            Picker("Target", selection: $draft.cases[index].target) {
                                Text("Team").tag("team")
                                Text("Solo").tag("solo")
                            }
                            Stepper(
                                "Pass \(draft.cases[index].passingScore)",
                                value: $draft.cases[index].passingScore, in: 0...100
                            )
                        }
                        HStack {
                            Stepper(
                                "Timeout · \(draft.cases[index].timeoutSeconds / 60) min",
                                value: $draft.cases[index].timeoutSeconds,
                                in: 30...7_200,
                                step: 30
                            )
                            if draft.cases[index].target == "team" {
                                Picker("Team", selection: $draft.cases[index].teamID) {
                                    Text("Selected team when run").tag("")
                                    ForEach(model.agentTeams) { team in
                                        Text(team.name).tag(team.id.uuidString)
                                    }
                                }
                            }
                        }
                        DisclosureGroup("Case orchestration budget") {
                            VStack(alignment: .leading, spacing: 5) {
                                Stepper(
                                    "Jobs · \(caseBudget(index).wrappedValue.maxJobs)",
                                    value: caseBudgetValue(index, \.maxJobs), in: 1...16
                                )
                                Stepper(
                                    "Rounds · \(caseBudget(index).wrappedValue.maxRounds)",
                                    value: caseBudgetValue(index, \.maxRounds), in: 1...8
                                )
                                Stepper(
                                    "Model calls · \(caseBudget(index).wrappedValue.maxModelCalls)",
                                    value: caseBudgetValue(index, \.maxModelCalls), in: 1...48
                                )
                                Stepper(
                                    "Concurrent calls · \(caseBudget(index).wrappedValue.maxConcurrentCalls)",
                                    value: caseBudgetValue(index, \.maxConcurrentCalls), in: 1...8
                                )
                                Stepper(
                                    "Hosted tokens · \(caseBudget(index).wrappedValue.maxMeteredTokens)",
                                    value: caseBudgetValue(index, \.maxMeteredTokens),
                                    in: 1_000...2_000_000,
                                    step: 50_000
                                )
                            }
                            .font(.system(size: 8))
                        }
                        TextField("Optional subjective rubric", text: $draft.cases[index].rubric, axis: .vertical)
                        if !draft.cases[index].rubric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Picker("Blind judge", selection: $draft.cases[index].judgeProfileID) {
                                Text("No subjective judge").tag("")
                                ForEach(model.agentProfiles.filter { $0.role == .reviewer }) { profile in
                                    Text(profile.name).tag(profile.id.uuidString)
                                }
                            }
                        }
                        ForEach(draft.cases[index].assertions.indices, id: \.self) { assertionIndex in
                            HStack {
                                Picker("Assertion", selection: $draft.cases[index].assertions[assertionIndex].kind) {
                                    ForEach([
                                        "command", "path_exists", "path_absent", "file_exact",
                                        "file_contains", "file_regex", "changed_paths_allowed",
                                        "changed_paths_forbidden", "json_value", "json_schema",
                                        "output_contains", "output_regex",
                                    ], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                                }
                                TextField(
                                    draft.cases[index].assertions[assertionIndex].kind == "command" ? "Command" : "Path",
                                    text: draft.cases[index].assertions[assertionIndex].kind == "command"
                                        ? $draft.cases[index].assertions[assertionIndex].command
                                        : $draft.cases[index].assertions[assertionIndex].path
                                )
                                if !["path_exists", "path_absent"].contains(
                                    draft.cases[index].assertions[assertionIndex].kind
                                ) {
                                    TextField(
                                        "Expected value or JSON",
                                        text: assertionValueBinding(index, assertionIndex)
                                    )
                                }
                                Toggle("Required", isOn: $draft.cases[index].assertions[assertionIndex].required)
                                    .toggleStyle(.checkbox)
                                Button(role: .destructive) {
                                    draft.cases[index].assertions.remove(at: assertionIndex)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain)
                            }
                        }
                        Button {
                            draft.cases[index].assertions.append(EvaluationAssertion())
                        } label: { Label("Add Assertion", systemImage: "plus") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                }
                Button {
                    draft.cases.append(EvaluationCase(name: "New case", prompt: "Describe the task."))
                } label: { Label("Add Case", systemImage: "plus") }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.tags = tags.split(separator: ",").map(String.init)
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(
                    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.cases.contains { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                )
            }
        }
        .padding(20)
        .frame(width: 720, height: 760)
    }

    private func caseBudget(_ index: Int) -> Binding<OrchestrationBudget> {
        Binding(
            get: {
                guard draft.cases.indices.contains(index) else { return OrchestrationBudget() }
                return draft.cases[index].budget ?? OrchestrationBudget()
            },
            set: { value in
                guard draft.cases.indices.contains(index) else { return }
                draft.cases[index].budget = value
            }
        )
    }

    private func caseBudgetValue(
        _ index: Int,
        _ keyPath: WritableKeyPath<OrchestrationBudget, Int>
    ) -> Binding<Int> {
        Binding(
            get: { caseBudget(index).wrappedValue[keyPath: keyPath] },
            set: { value in
                var budget = caseBudget(index).wrappedValue
                budget[keyPath: keyPath] = value
                caseBudget(index).wrappedValue = budget
            }
        )
    }

    private func caseTagsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.cases.indices.contains(index) else { return "" }
                return draft.cases[index].tags.joined(separator: ", ")
            },
            set: { value in
                guard draft.cases.indices.contains(index) else { return }
                draft.cases[index].tags = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            }
        )
    }

    private func assertionValueBinding(_ caseIndex: Int, _ assertionIndex: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.cases.indices.contains(caseIndex),
                      draft.cases[caseIndex].assertions.indices.contains(assertionIndex),
                      let value = draft.cases[caseIndex].assertions[assertionIndex].value
                else { return "" }
                if case .string(let text) = value { return text }
                guard let data = try? JSONEncoder().encode(value) else { return "" }
                return String(data: data, encoding: .utf8) ?? ""
            },
            set: { text in
                guard draft.cases.indices.contains(caseIndex),
                      draft.cases[caseIndex].assertions.indices.contains(assertionIndex)
                else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    draft.cases[caseIndex].assertions[assertionIndex].value = nil
                } else if let data = trimmed.data(using: .utf8),
                          let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                {
                    draft.cases[caseIndex].assertions[assertionIndex].value = value
                } else {
                    draft.cases[caseIndex].assertions[assertionIndex].value = .string(text)
                }
            }
        )
    }
}

struct WorkspaceKnowledgeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var enabled = true
    @State private var embeddingModel = ""
    @State private var exclusions = ""
    @State private var memoryDraft: WorkspaceMemoryDraft?
    @State private var confirmDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace Knowledge")
                        .font(.system(size: 16, weight: .bold))
                    Text("A local, workspace-isolated index of project text and memories you explicitly approve.")
                        .font(.system(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Index this workspace", isOn: $enabled)
                    TextField(
                        "Optional local Ollama embedding model",
                        text: $embeddingModel,
                        prompt: Text("Leave empty for fast text search only")
                    )
                    TextField(
                        "Additional exclusions (comma separated globs)",
                        text: $exclusions,
                        prompt: Text("Generated/**, Fixtures/private-*.json")
                    )
                    Text("Embeddings use only the configured local Ollama /api/embed endpoint. Secret-shaped files, ignored files, vendor/build folders, symlink escapes, binary files, and files over 2 MB are excluded.")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Save") {
                            model.configureWorkspaceKnowledge(
                                enabled: enabled,
                                embeddingModel: embeddingModel,
                                exclusions: exclusions.split(separator: ",").map {
                                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                }.filter { !$0.isEmpty }
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        Button("Rebuild Index") { model.rebuildWorkspaceKnowledge() }
                            .disabled(!enabled || model.isBusy)
                        Spacer()
                        Button("Delete All Workspace Knowledge…", role: .destructive) {
                            confirmDeleteAll = true
                        }
                    }
                    if let status = model.knowledgeStatus {
                        HStack(spacing: 14) {
                            metric("Files", status.documentCount)
                            metric("Chunks", status.chunkCount)
                            metric("Memories", status.memoryCount)
                            Spacer()
                            Text(status.embeddingModel.isEmpty ? "FTS5 text search" : "Text + local vectors")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        if let error = status.lastError, !error.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(LocusTheme.coral)
                        }
                    }
                }
                .padding(12)
                .locusCard()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("APPROVED MEMORY")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(LocusTheme.muted)
                        Spacer()
                        Button("Remember") { memoryDraft = .new }
                    }
                    Text("Conversation suggestions are never saved automatically. Remember is the explicit approval boundary.")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    if model.workspaceMemories.isEmpty {
                        Text("No approved decisions, conventions, or facts yet.")
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .padding(.vertical, 10)
                    }
                    ForEach(model.workspaceMemories) { memory in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: memory.pinned ? "pin.fill" : "bookmark")
                                    .foregroundStyle(memory.stale ? LocusTheme.warning : LocusTheme.signalDeep)
                                Text(memory.title).font(.system(size: 10, weight: .semibold))
                                if memory.stale {
                                    Text("STALE").font(.system(size: 7, weight: .bold)).foregroundStyle(LocusTheme.warning)
                                }
                                Spacer()
                                Menu {
                                    if memory.sourceRunID != nil || memory.sourceSessionID != nil {
                                        Button("Open Source") {
                                            model.openWorkspaceMemorySource(memory)
                                        }
                                    }
                                    Button("Edit") { memoryDraft = .existing(memory) }
                                    Button(memory.pinned ? "Unpin" : "Pin") {
                                        var value = memory; value.pinned.toggle()
                                        model.updateWorkspaceMemory(value)
                                    }
                                    Button(memory.stale ? "Mark Current" : "Mark Stale") {
                                        var value = memory; value.stale.toggle()
                                        model.updateWorkspaceMemory(value)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        model.deleteWorkspaceMemory(memory)
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                            }
                            Text(memory.content)
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(5)
                                .textSelection(.enabled)
                            if !memory.tags.isEmpty {
                                Text(memory.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        .padding(10)
                        .locusCard()
                    }
                }
            }
            .padding(20)
        }
        .task { await model.refreshWorkspaceKnowledge(); syncDraft() }
        .onChange(of: model.knowledgeStatus) { _, _ in syncDraft() }
        .sheet(item: $memoryDraft) { draft in
            WorkspaceMemoryEditor(draft: draft) { value in
                switch value.original {
                case .none:
                    model.rememberWorkspaceFact(
                        title: value.title, content: value.content,
                        tags: value.tags.split(separator: ",").map(String.init)
                    )
                case .some(var memory):
                    memory.title = value.title
                    memory.content = value.content
                    memory.tags = value.tags.split(separator: ",").map(String.init)
                    model.updateWorkspaceMemory(memory)
                }
                memoryDraft = nil
            }
        }
        .confirmationDialog(
            "Delete all knowledge for this workspace?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete Index and Memories", role: .destructive) {
                model.deleteAllWorkspaceKnowledge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chat transcripts and workspace files are not removed.")
        }
    }

    private func syncDraft() {
        guard let status = model.knowledgeStatus else { return }
        enabled = status.enabled
        embeddingModel = status.embeddingModel
        exclusions = (status.exclusions ?? []).joined(separator: ", ")
    }

    private func metric(_ name: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(name).font(.system(size: 7)).foregroundStyle(LocusTheme.muted)
        }
    }
}

private struct WorkspaceMemoryDraft: Identifiable {
    let id = UUID()
    var original: WorkspaceMemory?
    var title: String
    var content: String
    var tags: String

    static var new: Self { .init(original: nil, title: "", content: "", tags: "") }
    static func existing(_ memory: WorkspaceMemory) -> Self {
        .init(
            original: memory, title: memory.title, content: memory.content,
            tags: memory.tags.joined(separator: ", ")
        )
    }
}

private struct WorkspaceMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: WorkspaceMemoryDraft
    let onSave: (WorkspaceMemoryDraft) -> Void

    init(draft: WorkspaceMemoryDraft, onSave: @escaping (WorkspaceMemoryDraft) -> Void) {
        _value = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(value.original == nil ? "Remember for this workspace" : "Edit workspace memory")
                .font(.system(size: 14, weight: .bold))
            TextField("Title", text: $value.title)
            TextEditor(text: $value.content)
                .font(.system(size: 10))
                .frame(minHeight: 180)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
            TextField("Tags", text: $value.tags, prompt: Text("decision, convention, fact"))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(value) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }
}
