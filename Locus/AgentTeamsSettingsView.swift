import SwiftUI

struct AgentTeamsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingPrimaryAgent = false
    @State private var editingProfile: AgentProfile?
    @State private var editingTeam: AgentTeam?
    @State private var editingSuite: EvaluationSuite?
    @State private var evaluationReport: EvaluationReport?
    @State private var consentAccount: ProviderAccount?
    @State private var quickTeamPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader
                quickTeamSection
                primaryAgentSection
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
        .sheet(isPresented: $quickTeamPresented) {
            QuickTeamBuilderView(suggestedName: model.suggestedQuickTeamName())
                .environmentObject(model)
        }
        .sheet(isPresented: $editingPrimaryAgent) {
            AgentBehaviorEditor(
                title: "Primary Agent",
                behavior: model.primaryAgentBehavior,
                modelName: model.selectedModel
            ) {
                model.savePrimaryAgentBehavior($0)
                editingPrimaryAgent = false
            }
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

    private var quickTeamSection: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.3.sequence.fill")
                .font(.locus(size: 18, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .frame(width: 42, height: 42)
                .background(LocusTheme.signal.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("QUICK TEAM")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                Text("Choose models visually and start using the team right away.")
                    .font(.locus(size: 11, weight: .semibold))
                Text("Pick a dispatcher, a lead editor, and optional read-only helpers. Everything remains editable in the advanced sections below.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Create Quick Team…") { quickTeamPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .controlSize(.small)
                .disabled(model.isBusy)
                .accessibilityIdentifier("settings.quickTeam.create")
        }
        .padding(14)
        .locusCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.quickTeam")
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLOBAL SCHEDULER")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Stepper(
                "Up to \(model.globalAgentConcurrency) simultaneous model calls",
                value: $model.globalAgentConcurrency,
                in: 1...8
            )
            .font(.locus(size: 10, weight: .semibold))
            Text("Shared fairly across running chats. Expired worker leases are reclaimed after a crash.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(12)
        .locusCard()
    }

    private var primaryAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRIMARY AGENT")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text(model.primaryAgentBehavior.displayName)
                        .font(.locus(size: 12, weight: .semibold))
                    Text("Uses the selected conversation model · \(model.selectedModel)")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Edit Behavior") { editingPrimaryAgent = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Edit its name, description, response style, mode-specific guidance, capability ceilings, memory behavior, and runtime limits. The real model identity and safety rules stay factual and locked.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .locusCard()
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Agents & Teams")
                .font(.locus(size: 16, weight: .bold))
            Text("Create explicit model roles, then combine them into a dispatcher-led team with safely ordered coding agents.")
                .font(.locus(size: 10))
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
                            Text(profile.name).font(.locus(size: 11, weight: .semibold))
                            Text("\(profile.role.title) · \(routeTitle(profile.route)) · \(profile.model)")
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingProfile = profile }
                            .buttonStyle(.locus())
                        Button(role: .destructive) { model.removeAgentProfile(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.locus())
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
                dispatchApprovalMode: .preview,
                routingMode: .scorecard,
                routingWeights: .init()
            )
        } content: {
            if model.agentTeams.isEmpty {
                emptyRow("Teams are explicit: add a dispatcher, a lead writer, other coding agents, and any read-only specialists.")
            } else {
                ForEach(model.agentTeams) { team in
                    let errors = AgentTeamValidation.errors(team: team, profiles: model.agentProfiles)
                    HStack(spacing: 10) {
                        Image(systemName: errors.isEmpty ? "person.2.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(errors.isEmpty ? LocusTheme.signalDeep : LocusTheme.coral)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.name).font(.locus(size: 11, weight: .semibold))
                            Text(errors.first ?? "\(team.memberIDs.count) members · \(team.budget.maxConcurrentCalls) concurrent calls · \(team.budget.callBudgetMode.title.lowercased())")
                                .font(.locus(size: 8))
                                .foregroundStyle(errors.isEmpty ? LocusTheme.muted : LocusTheme.coral)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editingTeam = team }
                            .buttonStyle(.locus())
                        Button(role: .destructive) { model.removeAgentTeam(team) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.locus())
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
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Text("Locus asks once per account before a dispatcher may route team data to it automatically.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            ForEach(model.providerAccounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName).font(.locus(size: 10, weight: .semibold))
                        Text(account.resolvedBaseURL).font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    if model.teamRoutingConsentAccountIDs.contains(account.id) {
                        Button("Revoke") { model.revokeAutomaticRoutingConsent(for: account.id) }
                            .buttonStyle(.locus())
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
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Toggle("Export completed runs with OTLP/HTTP", isOn: $model.settings.otlpExportEnabled)
            TextField("https://collector.example", text: $model.settings.otlpEndpoint)
                .textFieldStyle(.roundedBorder)
            SecureField(
                "Authorization header (optional)",
                text: $model.settings.otlpAuthorization
            )
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Metadata sampling")
                Slider(value: $model.settings.otlpSamplingRate, in: 0...1, step: 0.05)
                Text("\(Int(model.settings.otlpSamplingRate * 100))%")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            Text("Metadata export is off by default. The authorization value is stored unencrypted in local app settings and is never written to logs or traces. Visible content requires a separate confirmation for each run.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
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
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Button("Import JSON") { model.importEvaluationSuite() }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
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
                            Text(suite.name).font(.locus(size: 10, weight: .semibold))
                            Text("\(suite.cases.count) cases · disposable checkouts")
                                .font(.locus(size: 8))
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
                        Button("Edit") { editingSuite = suite }.buttonStyle(.locus())
                        Button("Results") {
                            Task { evaluationReport = await model.loadEvaluationReport(suite) }
                        }
                        .buttonStyle(.locus())
                        Button { model.exportEvaluationSuite(suite) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.locus())
                        Button(role: .destructive) { model.deleteEvaluationSuite(suite) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.locus())
                        .disabled(model.isBusy)
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
            if let status = model.evaluationStatus {
                Label(status, systemImage: model.activeEvaluationID == nil ? "checkmark.circle" : "progress.indicator")
                    .font(.locus(size: 9, weight: .medium))
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
            .font(.locus(size: 9))
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
                    .font(.locus(size: 8, weight: .bold))
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

struct QuickTeamBuilderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuickTeamDraft
    @State private var activeLane: Lane = .dispatcher
    @State private var search = ""
    @State private var consentAccount: ProviderAccount?
    @State private var creationError: String?

    private enum Lane: String, CaseIterable, Identifiable {
        case dispatcher
        case lead
        case helpers

        var id: String { rawValue }
        var title: String {
            switch self {
            case .dispatcher: "Dispatcher"
            case .lead: "Lead editor"
            case .helpers: "Helpers"
            }
        }
        var symbol: String {
            switch self {
            case .dispatcher: "point.3.connected.trianglepath.dotted"
            case .lead: "hammer.fill"
            case .helpers: "person.2.fill"
            }
        }
        var detail: String {
            switch self {
            case .dispatcher: "Plans and assigns work"
            case .lead: "Can edit workspace files"
            case .helpers: "Read-only research and review"
            }
        }
    }

    private struct ChoiceSection: Identifiable {
        let id: String
        let title: String
        let choices: [QuickTeamModelChoice]
        let emptyMessage: String?
    }

    init(suggestedName: String) {
        _draft = State(initialValue: QuickTeamDraft(name: suggestedName))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    lanePicker
                    modelCatalog
                    runSummary
                    consentSection
                }
                .padding(20)
            }
            .accessibilityIdentifier("quickTeam.scroll")
            Divider()
            footer
        }
        .frame(width: 700, height: 660)
        .background(LocusTheme.paper)
        .accessibilityIdentifier("quickTeam.builder")
        .task {
            await model.refreshMetadata()
            await model.refreshAccountCatalogs(force: true)
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
            Text("The dispatcher may send the task and specialist evidence to this provider during a team run. Credentials are never stored in the team.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.locus(size: 16, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .frame(width: 38, height: 38)
                .background(LocusTheme.signal.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Create a Quick Team")
                    .font(.locus(size: 16, weight: .bold))
                Text("Choose a lane, then click a model. Advanced settings remain available afterward.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.locus(size: 10, weight: .bold))
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Close quick team builder")
            .accessibilityIdentifier("quickTeam.close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TEAM NAME")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            TextField("Quick Team", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Quick team name")
                .accessibilityIdentifier("quickTeam.name")
        }
    }

    private var lanePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. CHOOSE WHERE THE MODEL WILL WORK")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            HStack(alignment: .top, spacing: 10) {
                ForEach(Lane.allCases) { lane in
                    laneCard(lane)
                }
            }
        }
    }

    private func laneCard(_ lane: Lane) -> some View {
        let selected = activeLane == lane
        return Button {
            activeLane = lane
            creationError = nil
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: lane.symbol)
                        .foregroundStyle(selected ? LocusTheme.signalDeep : LocusTheme.muted)
                    Text(lane.title)
                        .font(.locus(size: 11, weight: .semibold))
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LocusTheme.signalDeep)
                    }
                }
                Text(laneSelectionTitle(lane))
                    .font(.locus(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(laneHasSelection(lane) ? LocusTheme.ink : LocusTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(minHeight: 23, alignment: .topLeading)
                Text(lane.detail)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(selected ? LocusTheme.signal.opacity(0.09) : LocusTheme.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? LocusTheme.signalDeep.opacity(0.65) : LocusTheme.line, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(lane.title), \(laneSelectionTitle(lane))")
        .accessibilityValue(selected ? "Active lane" : "Not active")
        .accessibilityIdentifier("quickTeam.lane.\(lane.rawValue)")
    }

    private var modelCatalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("2. PICK \(activeLane.title.uppercased()) MODELS")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text(activeLane == .helpers
                        ? "Choose any number of helpers. Click again to remove one."
                        : "Choose one model. Dispatcher and lead may use the same model.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                TextField("Search models", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityIdentifier("quickTeam.search")
            }

            if choiceSections.allSatisfy({ $0.choices.isEmpty }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(search.isEmpty
                        ? "No catalog models are available yet. Connect a provider or install an Ollama model."
                        : "No models match “\(search)”.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                    Button("Manage Models & Providers…") { openProviders() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("quickTeam.manageProviders")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LocusTheme.white.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(choiceSections) { section in
                        if !section.choices.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.title.uppercased())
                                    .font(.locus(size: 8, weight: .bold))
                                    .tracking(0.7)
                                    .foregroundStyle(LocusTheme.muted)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 205), spacing: 8)],
                                    alignment: .leading,
                                    spacing: 8
                                ) {
                                    ForEach(section.choices) { choice in
                                        modelCard(choice)
                                    }
                                }
                            }
                        } else if search.isEmpty, let emptyMessage = section.emptyMessage {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.title.uppercased())
                                    .font(.locus(size: 8, weight: .bold))
                                    .tracking(0.7)
                                    .foregroundStyle(LocusTheme.muted)
                                HStack(spacing: 10) {
                                    Text(emptyMessage)
                                        .font(.locus(size: 8))
                                        .foregroundStyle(LocusTheme.muted)
                                    Spacer()
                                    Button("Manage…") { openProviders() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .accessibilityLabel("Manage models for \(section.title)")
                                }
                                .padding(10)
                                .background(LocusTheme.white.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    private func modelCard(_ choice: QuickTeamModelChoice) -> some View {
        let selected = isSelected(choice, for: activeLane)
        let unavailableAsHelper = activeLane == .helpers
            && (choice == draft.dispatcher || choice == draft.leadEditor)
        return Button {
            choose(choice, for: activeLane)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? LocusTheme.signalDeep : LocusTheme.muted)
                    Text(choice.model)
                        .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 5) {
                    Text(choice.providerShortName)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    assignmentBadges(choice)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .background(selected ? LocusTheme.signal.opacity(0.09) : LocusTheme.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? LocusTheme.signalDeep.opacity(0.62) : LocusTheme.line, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .disabled(unavailableAsHelper)
        .help(unavailableAsHelper
            ? "This model already has a required role."
            : "Use \(choice.model) as \(activeLane.title.lowercased())")
        .accessibilityLabel("\(choice.model) from \(choice.providerName)")
        .accessibilityValue(accessibilityAssignments(choice))
        .accessibilityIdentifier("quickTeam.model.\(choice.id)")
    }

    @ViewBuilder
    private func assignmentBadges(_ choice: QuickTeamModelChoice) -> some View {
        if draft.dispatcher == choice { assignmentBadge("D") }
        if draft.leadEditor == choice { assignmentBadge("L") }
        if draft.helpers.contains(choice) { assignmentBadge("H") }
    }

    private func assignmentBadge(_ label: String) -> some View {
        Text(label)
            .font(.locus(size: 7, weight: .bold))
            .foregroundStyle(LocusTheme.signalDeep)
            .frame(width: 16, height: 16)
            .background(LocusTheme.signal.opacity(0.12))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT HAPPENS WHEN YOU RUN IT")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            summaryRow("Dispatcher chooses only the useful helpers", symbol: "arrow.triangle.branch")
            summaryRow("Lead editor is the only quick-team member that can edit files", symbol: "lock.shield")
            summaryRow("You review the complete plan once before work starts", symbol: "checkmark.shield")
            summaryRow("Advanced roles, budgets, routing, and instructions remain editable", symbol: "slider.horizontal.3")
        }
        .padding(12)
        .locusCard()
    }

    private func summaryRow(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.locus(size: 9))
            .foregroundStyle(LocusTheme.inkSoft)
    }

    @ViewBuilder
    private var consentSection: some View {
        let accounts = model.missingQuickTeamRoutingAccounts(for: draft)
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label("Hosted routing needs your approval", systemImage: "lock.shield.fill")
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
                Text("Approve each selected hosted account before creating the team. This never stores its credentials in the team.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                ForEach(accounts) { account in
                    HStack {
                        Text(account.displayName)
                            .font(.locus(size: 9, weight: .medium))
                        Spacer()
                        Button("Allow") { consentAccount = account }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Allow automatic routing for \(account.displayName)")
                            .accessibilityIdentifier("quickTeam.consent.\(account.id.uuidString)")
                    }
                }
            }
            .padding(12)
            .background(LocusTheme.coral.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LocusTheme.coral.opacity(0.35))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = creationError ?? blockingMessage {
                Label(message, systemImage: "info.circle")
                    .font(.locus(size: 8))
                    .foregroundStyle(creationError == nil ? LocusTheme.muted : LocusTheme.coral)
                    .lineLimit(2)
                    .accessibilityIdentifier("quickTeam.status")
            } else {
                Text("Ready to create and select \(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)).")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .accessibilityIdentifier("quickTeam.cancel")
            Button("Create & Use Team") { createTeam() }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(blockingMessage != nil)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("quickTeam.create")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(LocusTheme.paper)
    }

    private var choiceSections: [ChoiceSection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allChoiceSections.map { section in
            ChoiceSection(
                id: section.id,
                title: section.title,
                choices: section.choices.filter { choice in
                    query.isEmpty
                        || choice.model.lowercased().contains(query)
                        || choice.providerName.lowercased().contains(query)
                },
                emptyMessage: section.emptyMessage
            )
        }
    }

    private var allChoiceSections: [ChoiceSection] {
        model.modelPickerSections.map { section in
            let route = section.account.map { AgentRoute.providerAccount($0.id) }
                ?? .localOllama
            let choices = section.models.map { modelName in
                QuickTeamModelChoice(
                    route: route,
                    providerName: section.title,
                    providerShortName: section.account?.shortName ?? "Local",
                    model: modelName
                )
            }
            return ChoiceSection(
                id: section.id,
                title: section.title,
                choices: choices,
                emptyMessage: section.emptyMessage
            )
        }
    }

    private var availableChoices: Set<QuickTeamModelChoice> {
        Set(allChoiceSections.flatMap(\.choices))
    }

    private var blockingMessage: String? {
        if model.isBusy { return "Stop the active run before creating a team." }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the team a name." }
        if model.agentTeams.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return "A team with that name already exists."
        }
        guard let dispatcher = draft.dispatcher else { return "Choose a dispatcher model." }
        guard let lead = draft.leadEditor else { return "Choose a lead editor model." }
        let allAvailable = availableChoices
        if !allAvailable.contains(dispatcher) || !allAvailable.contains(lead)
            || draft.helpers.contains(where: { !allAvailable.contains($0) })
        {
            return "A selected model is no longer available. Refresh and choose again."
        }
        if let account = model.missingQuickTeamRoutingAccounts(for: draft).first {
            return "Allow routing for \(account.displayName) to continue."
        }
        return nil
    }

    private func laneSelectionTitle(_ lane: Lane) -> String {
        switch lane {
        case .dispatcher: draft.dispatcher?.model ?? "Choose one model"
        case .lead: draft.leadEditor?.model ?? "Choose one model"
        case .helpers:
            draft.helpers.isEmpty
                ? "Optional"
                : "\(draft.helpers.count) selected"
        }
    }

    private func laneHasSelection(_ lane: Lane) -> Bool {
        switch lane {
        case .dispatcher: draft.dispatcher != nil
        case .lead: draft.leadEditor != nil
        case .helpers: !draft.helpers.isEmpty
        }
    }

    private func isSelected(_ choice: QuickTeamModelChoice, for lane: Lane) -> Bool {
        switch lane {
        case .dispatcher: draft.dispatcher == choice
        case .lead: draft.leadEditor == choice
        case .helpers: draft.helpers.contains(choice)
        }
    }

    private func choose(_ choice: QuickTeamModelChoice, for lane: Lane) {
        creationError = nil
        switch lane {
        case .dispatcher:
            draft.dispatcher = choice
            draft.helpers.removeAll { $0 == choice }
            activeLane = draft.leadEditor == nil ? .lead : .dispatcher
        case .lead:
            draft.leadEditor = choice
            draft.helpers.removeAll { $0 == choice }
            activeLane = .helpers
        case .helpers:
            guard choice != draft.dispatcher, choice != draft.leadEditor else { return }
            if let index = draft.helpers.firstIndex(of: choice) {
                draft.helpers.remove(at: index)
            } else {
                draft.helpers.append(choice)
            }
        }
    }

    private func accessibilityAssignments(_ choice: QuickTeamModelChoice) -> String {
        var assignments: [String] = []
        if draft.dispatcher == choice { assignments.append("Dispatcher") }
        if draft.leadEditor == choice { assignments.append("Lead editor") }
        if draft.helpers.contains(choice) { assignments.append("Helper") }
        return assignments.isEmpty ? "Not assigned" : assignments.joined(separator: ", ")
    }

    private func createTeam() {
        creationError = nil
        switch model.createAndSelectQuickTeam(draft) {
        case .success:
            dismiss()
        case .failure(let error):
            creationError = error.localizedDescription
        }
    }

    private func openProviders() {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            model.presentSettings(.accounts)
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
                    Text(report.suite.name).font(.locus(size: 16, weight: .bold))
                    Text("Evaluation results")
                        .font(.locus(size: 9))
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
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(LocusTheme.muted)
                ForEach(report.comparison) { comparison in
                    HStack {
                        Text(comparison.configuration).font(.locus(size: 9, weight: .semibold))
                        Spacer()
                        Text("\(Int(comparison.passRate * 100))% pass")
                        Text("p95 \(comparison.p95LatencyMilliseconds) ms")
                        Text("\(comparison.modelCalls) calls")
                        Text("\(comparison.retries) retries")
                    }
                    .font(.locus(size: 8, design: .monospaced))
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
                                Text(result.caseID).font(.locus(size: 9, weight: .semibold))
                                Spacer()
                                Text("\(result.durationMilliseconds ?? 0) ms")
                                    .font(.locus(size: 7, design: .monospaced))
                            }
                            if let score = result.rubricScore {
                                Text("Subjective judge · \(Int(score))/100")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            if let error = result.error, !error.isEmpty {
                                Text(error).font(.locus(size: 8)).foregroundStyle(LocusTheme.coral)
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
            Text(value).font(.locus(size: 11, weight: .bold, design: .monospaced))
            Text(title).font(.locus(size: 7)).foregroundStyle(LocusTheme.muted)
        }
    }
}

private struct AgentBehaviorEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentBehavior
    @State private var showAdvanced = false
    @State private var showPreview = false
    let title: String
    let modelName: String
    let onSave: (AgentBehavior) -> Void

    init(
        title: String,
        behavior: AgentBehavior,
        modelName: String,
        onSave: @escaping (AgentBehavior) -> Void
    ) {
        _draft = State(initialValue: behavior)
        self.title = title
        self.modelName = modelName
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section("Identity and response") {
                        TextField("Display name", text: $draft.displayName)
                        TextField("What this agent is", text: $draft.selfDescription, axis: .vertical)
                            .lineLimit(2...5)
                        Picker("Tone", selection: $draft.responseStyle.tone) {
                            ForEach(AgentResponseTone.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Detail level", selection: $draft.responseStyle.verbosity) {
                            ForEach(AgentResponseVerbosity.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Use Markdown when helpful", isOn: $draft.responseStyle.useMarkdown)
                        Toggle("Cite files and outputs for factual claims", isOn: $draft.responseStyle.citeEvidence)
                    }

                    Section("Custom instructions") {
                        TextEditor(text: $draft.customInstructions)
                            .font(.locus(size: 10))
                            .frame(minHeight: 130)
                            .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
                        Text("These are added below locked safety, tool, permission, and factual model-identity rules.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }

                    Section {
                        Button(showAdvanced ? "Hide Mode, Memory & Capability Settings" : "Edit Mode, Memory & Capability Settings") {
                            withAnimation(LocusMotion.spatial) { showAdvanced.toggle() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .buttonStyle(.locus())
                        if showAdvanced { advancedFields }
                    }

                    Section("Prompt preview") {
                        Button(showPreview ? "Hide Preview" : "Show Prompt Layers") {
                            showPreview.toggle()
                        }
                        if showPreview {
                            Text(promptPreview)
                                .font(.locus(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .background(LocusTheme.white.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .padding(20)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Changes apply to the next turn; running work keeps its starting snapshot.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.clamp()
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
            }
            .padding(14)
            .background(LocusTheme.paper)
        }
        .frame(width: 650, height: 760)
    }

    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("MODE-SPECIFIC GUIDANCE")
                    .font(.locus(size: 8, weight: .bold)).foregroundStyle(LocusTheme.muted)
                TextField("Just Chat", text: $draft.modeInstructions.ask, axis: .vertical)
                TextField("Adaptive Work", text: $draft.modeInstructions.work, axis: .vertical)
                TextField("Plan", text: $draft.modeInstructions.plan, axis: .vertical)
                TextField("GSD", text: $draft.modeInstructions.build, axis: .vertical)
            }
            Divider()
            Group {
                Text("CAPABILITY CEILINGS")
                    .font(.locus(size: 8, weight: .bold)).foregroundStyle(LocusTheme.muted)
                Toggle("Workspace reading", isOn: $draft.capabilityPolicy.workspaceRead)
                Toggle("Workspace editing", isOn: $draft.capabilityPolicy.workspaceWrite)
                Toggle("Shell commands", isOn: $draft.capabilityPolicy.shell)
                Toggle("Network and browser", isOn: $draft.capabilityPolicy.network)
                Toggle("Skills and MCP integrations", isOn: $draft.capabilityPolicy.mcp)
                Toggle("Computer control", isOn: $draft.capabilityPolicy.computerControl)
                Toggle("iOS Simulator control", isOn: $draft.capabilityPolicy.simulatorControl)
                Text("These switches can only remove access. The selected mode, permission policy, and team role can narrow it further.")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            }
            Divider()
            Group {
                Text("MEMORY")
                    .font(.locus(size: 8, weight: .bold)).foregroundStyle(LocusTheme.muted)
                Toggle("Automatically recall relevant approved memory", isOn: $draft.memoryPolicy.recallEnabled)
                Toggle("Allow conservative Memory Inbox suggestions", isOn: $draft.memoryPolicy.proposalsEnabled)
                Toggle("Allow explicit memory search", isOn: $draft.memoryPolicy.searchEnabled)
                ForEach(AgentMemoryScope.allCases) { scope in
                    Toggle(scope.title, isOn: memoryScopeBinding(scope))
                }
                Stepper(
                    "Recall up to \(draft.memoryPolicy.maxAutomaticMemories) memories",
                    value: $draft.memoryPolicy.maxAutomaticMemories,
                    in: 0...20
                )
                Stepper(
                    "Memory context: \(draft.memoryPolicy.maxAutomaticTokens) tokens",
                    value: $draft.memoryPolicy.maxAutomaticTokens,
                    in: 0...4_000,
                    step: 100
                )
                Divider()
                Toggle(
                    "Carry encrypted session context between development chats",
                    isOn: $draft.memoryPolicy.crossChatContextEnabled
                )
                Stepper(
                    "Recall up to \(draft.memoryPolicy.maxAutomaticContextSnapshots) session snapshots",
                    value: $draft.memoryPolicy.maxAutomaticContextSnapshots,
                    in: 0...10
                )
                .disabled(!draft.memoryPolicy.crossChatContextEnabled)
                Stepper(
                    "Session context: \(draft.memoryPolicy.maxAutomaticContextTokens) tokens",
                    value: $draft.memoryPolicy.maxAutomaticContextTokens,
                    in: 0...4_000,
                    step: 100
                )
                .disabled(!draft.memoryPolicy.crossChatContextEnabled)
                Text("Just Chat receives neither workspace memory nor session snapshots. Unpinned snapshots expire after 30 days.")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            }
            Divider()
            Toggle("Custom tool-step limit", isOn: Binding(
                get: { draft.runtimePolicy.maxToolIterations != nil },
                set: { draft.runtimePolicy.maxToolIterations = $0 ? 40 : nil }
            ))
            if draft.runtimePolicy.maxToolIterations != nil {
                Stepper(
                    "Up to \(draft.runtimePolicy.maxToolIterations ?? 40) tool steps",
                    value: Binding(
                        get: { draft.runtimePolicy.maxToolIterations ?? 40 },
                        set: { draft.runtimePolicy.maxToolIterations = $0 }
                    ),
                    in: 1...100
                )
            }
            Toggle("Custom response timeout", isOn: Binding(
                get: { draft.runtimePolicy.timeoutSeconds != nil },
                set: { draft.runtimePolicy.timeoutSeconds = $0 ? 600 : nil }
            ))
            if draft.runtimePolicy.timeoutSeconds != nil {
                Stepper(
                    "Up to \(draft.runtimePolicy.timeoutSeconds ?? 600) seconds per response",
                    value: Binding(
                        get: { draft.runtimePolicy.timeoutSeconds ?? 600 },
                        set: { draft.runtimePolicy.timeoutSeconds = $0 }
                    ),
                    in: 30...3_600,
                    step: 30
                )
            }
            Toggle("Custom output limit", isOn: Binding(
                get: { draft.runtimePolicy.maxOutputTokens != nil },
                set: { draft.runtimePolicy.maxOutputTokens = $0 ? 4_096 : nil }
            ))
            if draft.runtimePolicy.maxOutputTokens != nil {
                Stepper(
                    "Up to \(draft.runtimePolicy.maxOutputTokens ?? 4_096) output tokens",
                    value: Binding(
                        get: { draft.runtimePolicy.maxOutputTokens ?? 4_096 },
                        set: { draft.runtimePolicy.maxOutputTokens = $0 }
                    ),
                    in: 256...128_000,
                    step: 256
                )
            }
            Text("Local and compatible provider APIs use these limits; managed providers may keep their own limits.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(.vertical, 6)
    }

    private func memoryScopeBinding(_ scope: AgentMemoryScope) -> Binding<Bool> {
        Binding(
            get: { draft.memoryPolicy.scopes.contains(scope) },
            set: { enabled in
                if enabled { draft.memoryPolicy.scopes.append(scope) }
                else { draft.memoryPolicy.scopes.removeAll { $0 == scope } }
            }
        )
    }

    private var promptPreview: String {
        let overlay = [
            ("Just Chat", draft.modeInstructions.ask),
            ("Work", draft.modeInstructions.work),
            ("Plan", draft.modeInstructions.plan),
            ("GSD", draft.modeInstructions.build),
        ].filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return """
        [LOCKED · factual]
        Model: \(modelName.isEmpty ? "selected conversation model" : modelName)
        Safety, permissions, mode boundaries, and tool access are supplied by Locus.

        [EDITABLE · behavior]
        Name: \(draft.displayName)
        Description: \(draft.selfDescription)
        Style: \(draft.responseStyle.tone.title), \(draft.responseStyle.verbosity.title)
        \(draft.customInstructions)
        \(overlay)

        [RUNTIME · per turn]
        Relevant approved memory and workspace instructions are added only when their scope and mode allow them.
        """
    }
}

struct AgentProfileEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentProfile
    @State private var tags: String
    @State private var connectionResult: String?
    @State private var testingConnection = false
    @State private var mcpTools: String
    @State private var mcpResources: String
    @State private var mcpPrompts: String
    @State private var advancedSettings = false
    @State private var editingBehavior = false
    let onSave: (AgentProfile) -> Void

    init(profile: AgentProfile, onSave: @escaping (AgentProfile) -> Void) {
        var value = profile
        value.behavior = profile.resolvedBehavior
        _draft = State(initialValue: value)
        _tags = State(initialValue: profile.capabilityTags.joined(separator: ", "))
        _mcpTools = State(initialValue: (profile.mcpPolicy?.tools ?? []).joined(separator: ", "))
        _mcpResources = State(initialValue: (profile.mcpPolicy?.resources ?? []).joined(separator: ", "))
        _mcpPrompts = State(initialValue: (profile.mcpPolicy?.prompts ?? []).joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    Form {
                            LabeledContent {
                                TextField("", text: $draft.name)
                                    .accessibilityLabel("Name")
                                    .accessibilityIdentifier("agent.name")
                            } label: {
                                Text("Name")
                                    .foregroundStyle(LocusTheme.ink)
                                    .accessibilityIdentifier("agent.nameLabel")
                            }
                            Picker("Role", selection: $draft.role) {
                                ForEach(AgentRole.allCases) { Text($0.title).tag($0) }
                            }
                            .accessibilityIdentifier("agent.role")
                            Picker("Provider route", selection: $draft.route) {
                                Text("Local Ollama").tag(AgentRoute.localOllama)
                                ForEach(model.providerAccounts) { account in
                                    Text(account.displayName).tag(AgentRoute.providerAccount(account.id))
                                }
                            }
                            .accessibilityIdentifier("agent.providerRoute")
                            modelPicker
                            if modelSelectionUnavailable {
                                Label(
                                    "This provider does not report \(draft.model). Choose a model from the menu before saving.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.coral)
                                .accessibilityIdentifier("agent.modelAvailability")
                            } else if modelChoices.isEmpty {
                                Text("This provider cannot list models, so enter its exact API model ID.")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .accessibilityIdentifier("agent.modelAvailability")
                            } else {
                                Text("Only models reported by the selected provider are shown.")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .accessibilityIdentifier("agent.modelAvailability")
                            }
                            Picker("Access ceiling", selection: $draft.accessCeiling) {
                                ForEach(AgentAccessCeiling.allCases) { Text($0.title).tag($0) }
                            }
                            .accessibilityIdentifier("agent.accessCeiling")
                            Picker("Classification", selection: $draft.metering) {
                                ForEach(AgentMetering.allCases) { Text($0.title).tag($0) }
                            }
                            .accessibilityIdentifier("agent.classification")
                            instructionsEditor
                            TextField("Capability tags", text: $tags, prompt: Text("code, tests, research"))
                                .accessibilityIdentifier("agent.capabilityTags")
                            advancedDisclosure
                                .id("agent.advancedSettings.section")
                            if draft.accessCeiling == .readOnly {
                                standardToolAccess
                            }
                            if let connectionResult {
                                Text(connectionResult)
                                    .font(.locus(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("agent.connectionResult")
                            }
                    }
                    .padding(20)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(LocusMotion.spatial, value: advancedSettings)
                }
                .accessibilityIdentifier("agent.scroll")
                .onChange(of: advancedSettings) { _, expanded in
                    guard expanded else { return }
                    withAnimation(LocusMotion.spatial) {
                        scrollProxy.scrollTo("agent.advancedSettings.section", anchor: .top)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()

            Divider()
            footer
                .frame(height: 56)
                .zIndex(1)
        }
        // Keep the fixed action footer inside the visible frame on the
        // shortest supported displays. The form above remains scrollable.
        .frame(width: 600, height: 640)
        .task { await refreshModels() }
        .onChange(of: draft.route) { _, _ in
            draft.model = ""
            connectionResult = nil
            Task { await refreshModels() }
        }
        .sheet(isPresented: $editingBehavior) {
            AgentBehaviorEditor(
                title: "\(draft.name) Behavior",
                behavior: draft.resolvedBehavior,
                modelName: draft.model
            ) { behavior in
                draft.behavior = behavior
                draft.name = behavior.displayName
                draft.instructions = behavior.customInstructions
                editingBehavior = false
            }
        }
    }

    private var modelPicker: some View {
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
                .buttonStyle(.locus())
                .help("Refresh models from this provider")
                .accessibilityLabel("Refresh provider models")
                .accessibilityIdentifier("agent.model.refresh")
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Custom role instructions")
                .font(LocusType.caption)
                .foregroundStyle(LocusTheme.inkSoft)
                .accessibilityIdentifier("agent.instructionsLabel")
            TextEditor(text: $draft.instructions)
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(LocusTheme.white.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.lineStrong, lineWidth: 1)
                }
                .accessibilityIdentifier("agent.instructions")
            Button("Use \(draft.role.title) Template") {
                draft.instructions = draft.role.defaultInstructions
                if draft.behavior == nil { draft.behavior = draft.resolvedBehavior }
                draft.behavior?.customInstructions = draft.role.defaultInstructions
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier("agent.useRoleTemplate")
            Button("Edit Full Behavior & Memory Policy…") {
                editingBehavior = true
            }
            .buttonStyle(.locus())
        }
    }

    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(LocusMotion.spatial) {
                    advancedSettings.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Advanced Settings")
                        .font(.locus(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(LocusTheme.signalDeep)
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 9, weight: .bold))
                        .foregroundStyle(LocusTheme.muted)
                        .rotationEffect(.degrees(advancedSettings ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.locus())
            .accessibilityValue(advancedSettings ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agent.advancedSettings")

            if advancedSettings {
                advancedSettingsContent
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
        }
    }

    private var standardToolAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STANDARD TOOL ACCESS")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Text("Read-only agents get only the tool groups you check. These choices can remove access; they never override Full Access, workspace boundaries, or the read-only ceiling.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent.standardToolAccessExplanation")
            toolAccessRow(
                "Workspace files",
                "Read, list, search, Git status/diff, and workspace knowledge",
                capabilityBinding(\.workspaceRead)
            )
            toolAccessRow(
                "Terminal commands",
                "Finite shell commands and managed background services",
                capabilityBinding(\.shell)
            )
            toolAccessRow(
                "Network and browser",
                "Web fetch plus the built-in browser tools",
                capabilityBinding(\.network)
            )
            toolAccessRow(
                "Skills and MCP",
                "Enabled skills and the MCP servers checked below",
                capabilityBinding(\.mcp)
            )
            toolAccessRow(
                "Search approved memory",
                "Automatic recall and the explicit memory search tool",
                memorySearchBinding
            )
            toolAccessRow(
                "Suggest memory",
                "May add a suggestion to the Memory Inbox; cannot approve it",
                memoryProposalBinding
            )
        }
        .padding(.vertical, 5)
        .accessibilityIdentifier("agent.standardToolAccess")
    }

    private func toolAccessRow(
        _ title: String, _ detail: String, _ binding: Binding<Bool>
    ) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.locus(size: 9, weight: .medium))
                Text(detail).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func capabilityBinding(
        _ keyPath: WritableKeyPath<AgentCapabilityPolicy, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { draft.resolvedBehavior.capabilityPolicy[keyPath: keyPath] },
            set: { enabled in
                var behavior = draft.resolvedBehavior
                behavior.capabilityPolicy[keyPath: keyPath] = enabled
                draft.behavior = behavior
            }
        )
    }

    private var memorySearchBinding: Binding<Bool> {
        Binding(
            get: {
                let policy = draft.resolvedBehavior.memoryPolicy
                return policy.recallEnabled && policy.searchEnabled
            },
            set: { enabled in
                var behavior = draft.resolvedBehavior
                behavior.memoryPolicy.recallEnabled = enabled
                behavior.memoryPolicy.searchEnabled = enabled
                draft.behavior = behavior
            }
        )
    }

    private var memoryProposalBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedBehavior.memoryPolicy.proposalsEnabled },
            set: { enabled in
                var behavior = draft.resolvedBehavior
                behavior.memoryPolicy.proposalsEnabled = enabled
                draft.behavior = behavior
            }
        )
    }

    private var advancedSettingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("RUNTIME LIMITS")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Stepper(
                "Timeout: \(draft.timeoutSeconds)s",
                value: $draft.timeoutSeconds,
                in: 30...3_600,
                step: 30
            )
            .accessibilityIdentifier("agent.advanced.timeout")
            Stepper(
                "Token limit: \(draft.tokenLimit.formatted())",
                value: $draft.tokenLimit,
                in: 1_024...1_000_000,
                step: 1_024
            )
            .accessibilityIdentifier("agent.advanced.tokenLimit")
            if draft.metering == .metered {
                TextField("Input $ / 1M tokens", value: $draft.inputCostPerMillion, format: .number)
                TextField("Output $ / 1M tokens", value: $draft.outputCostPerMillion, format: .number)
            }

            Divider()
            Text("MCP ACCESS · NONE BY DEFAULT")
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
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
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
    }

    private var footer: some View {
        HStack {
            Button(testingConnection ? "Testing…" : "Test Connection") {
                testingConnection = true
                Task {
                    connectionResult = await model.testAgentProfileConnection(draft)
                    testingConnection = false
                }
            }
            .disabled(testingConnection || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("agent.testConnection")

            Spacer()

            Button("Cancel") { dismiss() }
                .accessibilityIdentifier("agent.cancel")
            Button("Save") {
                draft.capabilityTags = tags.split(separator: ",").map(String.init)
                var policy = draft.mcpPolicy ?? MCPAgentPolicy()
                policy.tools = csv(mcpTools)
                policy.resources = csv(mcpResources)
                policy.prompts = csv(mcpPrompts)
                draft.mcpPolicy = policy
                if draft.behavior == nil { draft.behavior = draft.resolvedBehavior }
                draft.behavior?.displayName = draft.name
                draft.behavior?.customInstructions = draft.instructions
                draft.clamp()
                onSave(draft)
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
            .disabled(
                draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || modelSelectionUnavailable
            )
            .accessibilityIdentifier("agent.save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(LocusTheme.paper)
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
                values = account.kind == .custom ? reported : reported.filter {
                    ProviderModelFilter.matches(kind: account.kind, name: $0)
                }
            } else {
                values = ([account.preferredModel] + account.kind.curatedModels).filter {
                    account.kind == .custom
                        || ProviderModelFilter.matches(kind: account.kind, name: $0)
                }
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
        let engineErrors = (
            draft.resolvedSwarmPolicy.engine == .openAIResponses && !openAIEngineEligible
        ) ? ["OpenAI Responses requires an OpenAI API dispatcher on GPT-5.6."] : []
        let errors = AgentTeamValidation.errors(
            team: draft, profiles: model.agentProfiles
        ) + engineErrors
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
                    Picker("Lead writer", selection: $draft.defaultWriterID) {
                        Text("Choose…").tag(nil as UUID?)
                        ForEach(memberProfiles.filter { $0.accessCeiling.canWrite }) {
                            Text($0.name).tag($0.id as UUID?)
                        }
                    }
                    Text("The lead handles safe fallback and combined review fixes. Other write-capable members can own ordered coding jobs in the approved plan.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("teamEditor.multiWriterExplanation")
                    Toggle("Use isolated managed worktree for new Git tasks", isOn: $draft.useManagedWorktree)
                    Toggle("Run independent coding jobs in parallel worktrees", isOn: Binding(
                        get: { draft.resolvedParallelWriters },
                        set: { draft.parallelWriters = $0 }
                    ))
                        .disabled(!draft.useManagedWorktree)
                    Text("Each independent writer gets a private checkout. Locus integrates completed patches in plan order and stops with a visible conflict instead of guessing.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Section("Dispatch and routing") {
                        Label(
                            "Review each team plan once before any agent begins",
                            systemImage: "checkmark.shield"
                        )
                        .font(.locus(size: 9, weight: .medium))
                        Text("Run Plan approves the complete plan. Locus will not ask again for each model, agent, job, or step; security-sensitive tool permissions remain separate.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("teamEditor.oneTimeApproval")
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
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    Section("Adaptive read-only delegation") {
                        Toggle("Allow read-only agents to create bounded children", isOn: Binding(
                            get: { draft.resolvedSwarmPolicy.delegationMode == .readOnlyChildren },
                            set: { enabled in
                                updateSwarmPolicy {
                                    $0.delegationMode = enabled ? .readOnlyChildren : .flat
                                }
                            }
                        ))
                        .accessibilityIdentifier("teamEditor.readOnlyDelegation")
                        Picker("Execution engine", selection: Binding(
                            get: { draft.resolvedSwarmPolicy.engine },
                            set: { engine in updateSwarmPolicy { $0.engine = engine } }
                        )) {
                            ForEach(SwarmPolicy.Engine.allCases) { engine in
                                Text(engine.title).tag(engine)
                                    .disabled(engine == .openAIResponses && !openAIEngineEligible)
                            }
                        }
                        .accessibilityIdentifier("teamEditor.swarmEngine")
                        Text(openAIEngineEligible
                            ? "OpenAI-native orchestration is optional and uses the dispatcher's OpenAI API billing route."
                            : "OpenAI-native orchestration is available only with an OpenAI API dispatcher on GPT-5.6; ChatGPT plan accounts remain Locus-managed.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("teamEditor.swarmEngineEligibility")
                        Stepper(
                            "Maximum simultaneous agents: \(draft.budget.maxConcurrentCalls)",
                            value: $draft.budget.maxConcurrentCalls,
                            in: 1...8
                        )
                        .accessibilityIdentifier("teamEditor.maxSimultaneousAgents")
                        Stepper(
                            "Maximum total agents: \(draft.resolvedSwarmPolicy.maxTotalAgents)",
                            value: Binding(
                                get: { draft.resolvedSwarmPolicy.maxTotalAgents },
                                set: { value in updateSwarmPolicy { $0.maxTotalAgents = value } }
                            ),
                            in: 1...32
                        )
                        .accessibilityIdentifier("teamEditor.maxTotalAgents")
                        Stepper(
                            "Maximum depth: \(draft.resolvedSwarmPolicy.maxDepth)",
                            value: Binding(
                                get: { draft.resolvedSwarmPolicy.maxDepth },
                                set: { value in updateSwarmPolicy { $0.maxDepth = value } }
                            ),
                            in: 1...4
                        )
                        .accessibilityIdentifier("teamEditor.maxSwarmDepth")
                        Text("Children are always read-only and stay inside the approved goals, providers, and budgets. Writers can never delegate.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("teamEditor.writerDelegationExplanation")
                    }
                    Section("Hard budgets") {
                        Stepper("Delegated jobs: \(draft.budget.maxJobs)", value: $draft.budget.maxJobs, in: 1...16)
                        Stepper("Orchestration rounds: \(draft.budget.maxRounds)", value: $draft.budget.maxRounds, in: 1...8)
                        Picker("Call budget", selection: Binding(
                            get: { draft.budget.callBudgetMode },
                            set: { mode in
                                draft.budget.callBudgetMode = mode
                                if mode == .automatic {
                                    draft.budget.maxModelCalls = 100
                                }
                            }
                        )) {
                            ForEach(OrchestrationBudget.CallBudgetMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        if draft.budget.callBudgetMode == .fixed {
                            Stepper("Model calls: \(draft.budget.maxModelCalls)", value: $draft.budget.maxModelCalls, in: 1...100)
                        } else {
                            Text("Locus allocates calls in small slices and preserves enough capacity for later coding jobs, review, and the final handoff.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Stepper("Metered tokens: \(draft.budget.maxMeteredTokens.formatted())", value: $draft.budget.maxMeteredTokens, in: 1_000...2_000_000, step: 10_000)
                    }
                    if !errors.isEmpty {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(LocusTheme.coral)
                                .font(.locus(size: 9))
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

    private var openAIEngineEligible: Bool {
        guard let dispatcherID = draft.dispatcherID,
              let dispatcher = model.agentProfiles.first(where: { $0.id == dispatcherID }),
              case .providerAccount(let accountID) = dispatcher.route,
              model.providerAccounts.first(where: { $0.id == accountID })?.kind == .codex
        else { return false }
        let name = dispatcher.model.lowercased()
        return name == "gpt-5.6" || name.hasPrefix("gpt-5.6-")
    }

    private func updateSwarmPolicy(_ update: (inout SwarmPolicy) -> Void) {
        var policy = draft.resolvedSwarmPolicy
        update(&policy)
        draft.swarmPolicy = policy
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
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
            Section("Cases") {
                ForEach(draft.cases.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("Case name", text: $draft.cases[index].name)
                            Button(role: .destructive) {
                                if draft.cases.count > 1 { draft.cases.remove(at: index) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.locus())
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
                                    value: caseBudgetValue(index, \.maxModelCalls), in: 1...100
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
                            .font(.locus(size: 8))
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
                                    .buttonStyle(.locus())
                            }
                        }
                        Button {
                            draft.cases[index].assertions.append(EvaluationAssertion())
                        } label: { Label("Add Assertion", systemImage: "plus") }
                            .buttonStyle(.locus())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var enabled = true
    @State private var embeddingModel = ""
    @State private var exclusions = ""
    @State private var memoryDraft: WorkspaceMemoryDraft?
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteMemory = false
    @State private var selectedMemoryAgentID = "primary"
    @State private var showAdvancedMemory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Memory & Knowledge")
                        .font(.locus(size: 16, weight: .bold))
                    Text("Memory keeps durable things you want the agent to carry forward. You stay in control: suggestions wait in the Inbox, and only approved memory can be recalled.")
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                }
                HStack(alignment: .top, spacing: 12) {
                    memoryStep("1", "Agent suggests", "Clear preferences, decisions, facts, procedures, or relationships go to the Inbox.")
                    memoryStep("2", "You review", "Approve, replace an older conflict, edit, or reject it.")
                    memoryStep("3", "Relevant recall", "Locus combines text and optional local semantic matching, then explains why it recalled each item.")
                }
                HStack {
                    Text("Memory owner")
                        .font(.locus(size: 9, weight: .semibold))
                    Picker("Memory owner", selection: $selectedMemoryAgentID) {
                        Text("Primary · \(model.primaryAgentBehavior.displayName)")
                            .tag("primary")
                        ForEach(model.agentProfiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    Text("Personal and workspace memory are shared; agent memory follows this selection.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Spacer()
                }
                Button {
                    withAnimation(LocusMotion.spatial) {
                        showAdvancedMemory.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Advanced Memory Settings")
                            .font(.locus(size: 11, weight: .semibold))
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(LocusTheme.signalDeep)
                        Image(systemName: "chevron.right")
                            .font(.locus(size: 9, weight: .bold))
                            .foregroundStyle(LocusTheme.muted)
                            .rotationEffect(.degrees(showAdvancedMemory ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("memory.advancedSettings")

                if showAdvancedMemory {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("WORKSPACE SEARCH INDEX")
                            .font(.locus(size: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(LocusTheme.muted)
                        Text("This is separate from durable memory. It makes project files searchable for the current workspace; leaving the model empty uses fast text matching, while a local Ollama embedding model also finds related meaning and improves approved-memory recall.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
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
                            .font(.locus(size: 8))
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
                        HStack {
                            Text("BACKUP & MAINTENANCE")
                                .font(.locus(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Spacer()
                            Button("Review Health") {
                                model.reviewMemoryHealth(agentID: selectedMemoryAgentID)
                            }
                            .buttonStyle(.locus())
                            Button("Import Memory") {
                                model.importMemory(agentID: selectedMemoryAgentID)
                            }
                            .buttonStyle(.locus())
                            Button("Export Memory") {
                                model.exportMemory(agentID: selectedMemoryAgentID)
                            }
                            .buttonStyle(.locus())
                            Button("Delete All Memory…", role: .destructive) {
                                confirmDeleteMemory = true
                            }
                            .buttonStyle(.locus())
                        }
                        if let status = model.knowledgeStatus {
                            HStack(spacing: 14) {
                                metric("Indexed files", status.documentCount)
                                metric("Search chunks", status.chunkCount)
                                metric("Saved memories", model.workspaceMemories.count)
                                Spacer()
                                Text(status.embeddingModel.isEmpty ? "FTS5 text search" : "Text + local vectors")
                                    .font(.locus(size: 8, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            Text("Indexed files and search chunks make project content searchable; they do not create saved memories. Use Remember or approve an Inbox suggestion to save one.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if let error = status.lastError, !error.isEmpty {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.coral)
                            }
                        }
                        if let vault = model.memoryVaultStatus {
                            Divider()
                            Text("LOCAL STORAGE")
                                .font(.locus(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Text("\(vault.cipher) · user-only local key file (0600) · no Keychain access or sign-in prompts · memory text and optional semantic vectors are encrypted together · Inbox suggestions expire after \(vault.candidateTTLDays) days")
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .locusCard()
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
                }

                if let vault = model.memoryVaultStatus {
                    HStack(spacing: 10) {
                        Image(systemName: vault.encrypted ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(vault.encrypted ? LocusTheme.signalDeep : LocusTheme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vault.encrypted ? "Private memory on this Mac" : "Memory encryption unavailable")
                                .font(.locus(size: 10, weight: .semibold))
                            Text("Only approved items can be recalled. Search indexing, local storage, backup, and deletion controls are under Advanced Memory Settings.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Spacer()
                        metric("Inbox", vault.candidateCount)
                        metric("Conflicts", vault.conflictCount ?? 0)
                        metric("Stale", vault.staleCount ?? 0)
                    }
                    .padding(12)
                    .locusCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CROSS-CHAT CONTEXT")
                                .font(.locus(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Text("Encrypted rolling handoffs from development chats in this workspace")
                                .font(.locus(size: 10, weight: .semibold))
                        }
                        Spacer()
                        Text("\(model.contextSnapshots.count)")
                            .font(.locus(size: 9, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                        Button("Clear All", role: .destructive) {
                            model.clearContextSnapshots()
                        }
                        .disabled(model.contextSnapshots.isEmpty)
                    }
                    Text("Only Work, Plan, and GSD can save or recall these snapshots. Automatic recall is capped by the selected agent's memory policy; Just Chat never receives them.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.contextSnapshots.isEmpty {
                        Text("No session handoffs have been saved yet.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    } else {
                        ForEach(model.contextSnapshots.prefix(12)) { snapshot in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: snapshot.pinned ? "pin.fill" : "clock.arrow.circlepath")
                                    .foregroundStyle(snapshot.pinned ? LocusTheme.signalDeep : LocusTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.goal.isEmpty ? "Development session" : snapshot.goal)
                                        .font(.locus(size: 9, weight: .semibold))
                                        .lineLimit(2)
                                    if !snapshot.pending.isEmpty {
                                        Text("Pending: \(snapshot.pending)")
                                            .font(.locus(size: 8))
                                            .foregroundStyle(LocusTheme.muted)
                                            .lineLimit(2)
                                    }
                                    Text(Date(timeIntervalSince1970: snapshot.updatedAt), style: .relative)
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                Button(snapshot.pinned ? "Unpin" : "Pin") {
                                    model.setContextSnapshotPinned(snapshot, pinned: !snapshot.pinned)
                                }
                                .buttonStyle(.locus())
                                Button(role: .destructive) {
                                    model.deleteContextSnapshot(snapshot)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.locus())
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(12)
                .locusCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SKILL OBSERVATIONS")
                                .font(.locus(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Text("Evidence-backed improvement notes awaiting your review")
                                .font(.locus(size: 10, weight: .semibold))
                        }
                        Spacer()
                        Button("Export") { model.exportSkillObservations() }
                            .disabled(model.skillObservations.isEmpty)
                    }
                    if model.skillObservations.isEmpty {
                        Text("No observations recorded.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    } else {
                        ForEach(model.skillObservations.prefix(20)) { observation in
                            HStack(alignment: .top, spacing: 10) {
                                Text("#\(observation.number)")
                                    .font(.locus(size: 8, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(observation.title)
                                        .font(.locus(size: 9, weight: .semibold))
                                    if !observation.issue.isEmpty {
                                        Text(observation.issue)
                                            .font(.locus(size: 8))
                                            .foregroundStyle(LocusTheme.muted)
                                            .lineLimit(3)
                                    }
                                    Text("\(observation.skill) · \(observation.status.capitalized)")
                                        .font(.locus(size: 8, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                if observation.status == "OPEN" {
                                    Button("Actioned") {
                                        model.setSkillObservationStatus(observation, status: "ACTIONED")
                                    }
                                    .buttonStyle(.locus())
                                    Button("Decline") {
                                        model.setSkillObservationStatus(observation, status: "DECLINED")
                                    }
                                    .buttonStyle(.locus())
                                } else {
                                    Button("Reopen") {
                                        model.setSkillObservationStatus(observation, status: "OPEN")
                                    }
                                    .buttonStyle(.locus())
                                }
                                Button(role: .destructive) {
                                    model.deleteSkillObservation(observation)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.locus())
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(12)
                .locusCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MEMORY HEALTH")
                                .font(.locus(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Text("Indexing and saved memory are separate pipelines.")
                                .font(.locus(size: 10, weight: .semibold))
                        }
                        Spacer()
                        Button("Analyze Selected Chat") {
                            model.reprocessCurrentChatMemory(agentID: selectedMemoryAgentID)
                        }
                        .disabled(model.currentSessionID.isEmpty || model.isBusy)
                        .accessibilityIdentifier("memory.analyzeSelectedChat")
                    }

                    if let report = model.memoryDiagnosticReport {
                        HStack(spacing: 18) {
                            metric("Indexed files", report.indexedFiles)
                            metric("Search chunks", report.searchChunks)
                            metric("Inbox items", report.candidateCount)
                            metric("Saved memories", report.approvedCount)
                            Spacer()
                        }
                        Text("\(report.indexedFiles.formatted()) files and \(report.searchChunks.formatted()) chunks mean workspace knowledge is searchable. Zero saved memories is healthy until you approve an Inbox item or explicitly use Remember.")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()
                        HStack(spacing: 14) {
                            diagnosticLabel(
                                "Policy",
                                report.proposalPolicy?.capitalized ?? "Unknown",
                                healthy: report.proposalPolicy == "enabled"
                            )
                            diagnosticLabel(
                                "Suggestion tool",
                                report.proposeMemoryAvailable == true ? "Available" : "Unavailable",
                                healthy: report.proposeMemoryAvailable == true
                            )
                            diagnosticLabel(
                                "Scopes",
                                (report.enabledScopes ?? []).map(\.capitalized).joined(separator: ", ").nilIfEmpty
                                    ?? "None",
                                healthy: !(report.enabledScopes ?? []).isEmpty
                            )
                            diagnosticLabel(
                                "Recall",
                                "\(report.counts["recall:matched", default: 0]) matched · \(report.counts["recall:empty", default: 0]) empty",
                                healthy: true
                            )
                            Spacer()
                        }
                        HStack(spacing: 14) {
                            diagnosticLabel(
                                "Accepted",
                                "\(report.counts["proposal:accepted", default: 0])",
                                healthy: true
                            )
                            diagnosticLabel(
                                "Rejected",
                                "\(report.counts["proposal:rejected", default: 0] + report.counts["rejection:recorded", default: 0])",
                                healthy: report.counts["proposal:rejected", default: 0]
                                    + report.counts["rejection:recorded", default: 0] == 0
                            )
                            diagnosticLabel(
                                "Expired",
                                "\(report.expiredCount ?? 0)",
                                healthy: (report.expiredCount ?? 0) == 0
                            )
                            diagnosticLabel(
                                "Embedding",
                                report.embeddingError.nilIfEmpty == nil
                                    ? (report.embeddingModel.isEmpty ? "Text search" : report.embeddingModel)
                                    : "Needs attention",
                                healthy: report.embeddingError.isEmpty
                            )
                            Spacer()
                        }
                        HStack(spacing: 14) {
                            Text("Last proposal: \(diagnosticTime(report.lastProposal?.occurredAt))")
                            Text("Last approval: \(diagnosticTime(report.lastApproval?.occurredAt))")
                            Spacer()
                        }
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        if !report.historyAvailable {
                            Text("No proposal history recorded since diagnostics were added.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        } else if let latest = report.events.first {
                            Text("Latest pipeline event: \(latest.stage.replacingOccurrences(of: "_", with: " ")) · \(latest.outcome.replacingOccurrences(of: "_", with: " "))\(latest.reasonCode.isEmpty ? "" : " · \(latest.reasonCode.replacingOccurrences(of: "_", with: " "))")")
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        if !report.embeddingError.isEmpty {
                            Label(report.embeddingError, systemImage: "exclamationmark.triangle.fill")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.warning)
                        }
                    } else {
                        ProgressView("Loading memory diagnostics…")
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .locusCard()
                .accessibilityIdentifier("memory.health")

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Memory suggestions")
                            .font(LocusType.title)
                        Spacer()
                        if !model.memoryCandidates.isEmpty {
                            Text("\(model.memoryCandidates.count) waiting")
                                .font(LocusType.badge)
                                .foregroundStyle(LocusTheme.brandInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(LocusTheme.accentFill)
                                .clipShape(Capsule())
                        }
                    }
                    Text("In work modes, the agent may suggest only explicit preferences, repeated constraints, and confirmed decisions or outcomes. Suggestions never affect future answers until you approve them.")
                        .font(LocusType.callout)
                        .foregroundStyle(LocusTheme.textTertiary)
                    if model.memoryCandidates.isEmpty {
                        Text("No suggestions waiting for review.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .padding(.vertical, 8)
                    }
                    ForEach(model.memoryCandidates) { memory in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(memory.title).font(.locus(size: 10, weight: .semibold))
                                Text(memory.resolvedScope.title.uppercased())
                                    .font(LocusType.badge)
                                    .foregroundStyle(LocusTheme.accentAction)
                                Spacer()
                                Button("Reject", role: .destructive) {
                                    model.deleteWorkspaceMemory(
                                        memory,
                                        agentID: selectedMemoryAgentID
                                    )
                                }
                                .buttonStyle(.locus())
                                if !memory.hasConflicts {
                                    Button("Approve") {
                                        model.approveMemoryCandidate(
                                            memory,
                                            agentID: selectedMemoryAgentID
                                        )
                                    }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .tint(LocusTheme.ink)
                                }
                            }
                            Text(memory.content)
                                .font(LocusType.body)
                                .foregroundStyle(LocusTheme.textSecondary)
                            if let reason = memory.reason, !reason.isEmpty {
                                Label("Suggested because: \(reason)", systemImage: "lightbulb")
                                    .font(LocusType.caption)
                                    .foregroundStyle(LocusTheme.textTertiary)
                            }
                            if memory.hasConflicts {
                                Label("This may conflict with \(memory.conflicts?.map(\.title).joined(separator: ", ") ?? "an approved memory").", systemImage: "arrow.triangle.branch")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.warning)
                                HStack {
                                    Button("Keep Both") {
                                        model.approveMemoryCandidate(
                                            memory, agentID: selectedMemoryAgentID
                                        )
                                    }
                                    Button("Replace Older") {
                                        model.approveMemoryCandidate(
                                            memory,
                                            agentID: selectedMemoryAgentID,
                                            replacingConflicts: true
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(LocusTheme.ink)
                                }
                            }
                        }
                        .padding(12)
                        .locusCard()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("APPROVED MEMORY")
                            .font(.locus(size: 8, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(LocusTheme.muted)
                        Spacer()
                        Button("Remember") { memoryDraft = .new }
                    }
                    Text("Approved memories can be recalled automatically within their scope. Use Remember to add one directly without the Inbox.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Text("The vault stays encrypted on disk. An exported JSON file is intentionally readable so you can inspect or move it.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    if model.workspaceMemories.isEmpty {
                        Text("No approved decisions, conventions, or facts yet.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .padding(.vertical, 10)
                    }
                    ForEach(model.workspaceMemories) { memory in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: memory.pinned ? "pin.fill" : "bookmark")
                                    .foregroundStyle(memory.stale ? LocusTheme.warning : LocusTheme.signalDeep)
                                Text(memory.title).font(.locus(size: 10, weight: .semibold))
                                Text(memory.resolvedScope.title.uppercased())
                                    .font(.locus(size: 7, weight: .bold))
                                    .foregroundStyle(LocusTheme.signalDeep)
                                if memory.stale {
                                    Text("STALE").font(.locus(size: 7, weight: .bold)).foregroundStyle(LocusTheme.warning)
                                }
                                Text(memory.resolvedKind.title.uppercased())
                                    .font(.locus(size: 7, weight: .bold))
                                    .foregroundStyle(LocusTheme.muted)
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
                                        model.updateWorkspaceMemory(
                                            value,
                                            agentID: selectedMemoryAgentID
                                        )
                                    }
                                    Button(memory.stale ? "Mark Current" : "Mark Stale") {
                                        var value = memory; value.stale.toggle()
                                        model.updateWorkspaceMemory(
                                            value,
                                            agentID: selectedMemoryAgentID
                                        )
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        model.deleteWorkspaceMemory(
                                            memory,
                                            agentID: selectedMemoryAgentID
                                        )
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                            }
                            Text(memory.content)
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(5)
                                .textSelection(.enabled)
                            if !memory.tags.isEmpty {
                                Text(memory.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            Text("Confidence \(memory.resolvedConfidence, format: .percent.precision(.fractionLength(0)))\(memory.useCount.map { " · recalled \($0) time\($0 == 1 ? "" : "s")" } ?? "")")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                            if let why = memory.retrievalReason, !why.isEmpty {
                                Text("Why recalled: \(why)")
                                    .font(.locus(size: 8))
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
        .task(id: selectedMemoryAgentID) {
            await model.refreshWorkspaceKnowledge(agentID: selectedMemoryAgentID)
            syncDraft()
        }
        .onChange(of: model.knowledgeStatus) { _, _ in syncDraft() }
        .sheet(item: $memoryDraft) { draft in
            WorkspaceMemoryEditor(draft: draft) { value in
                switch value.original {
                case .none:
                    model.rememberWorkspaceFact(
                        title: value.title, content: value.content,
                        tags: value.tags.split(separator: ",").map(String.init),
                        scope: value.scope,
                        kind: value.kind,
                        confidence: value.confidence,
                        validUntil: value.expires ? value.validUntil.timeIntervalSince1970 : nil,
                        agentID: selectedMemoryAgentID
                    )
                case .some(var memory):
                    memory.title = value.title
                    memory.content = value.content
                    memory.tags = value.tags.split(separator: ",").map(String.init)
                    memory.scope = value.scope.rawValue
                    memory.kind = value.kind.rawValue
                    memory.confidence = value.confidence
                    memory.validUntil = value.expires
                        ? value.validUntil.timeIntervalSince1970 : nil
                    model.updateWorkspaceMemory(
                        memory,
                        agentID: selectedMemoryAgentID
                    )
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
                model.deleteAllWorkspaceKnowledge(agentID: selectedMemoryAgentID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chat transcripts and workspace files are not removed.")
        }
        .confirmationDialog(
            "Delete all visible memory?",
            isPresented: $confirmDeleteMemory,
            titleVisibility: .visible
        ) {
            Button("Delete Personal, Workspace & Agent Memory", role: .destructive) {
                model.deleteAllMemory(agentID: selectedMemoryAgentID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The project index, chats, and files stay intact. This cannot be undone unless you exported memory first.")
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
            Text(value.formatted()).font(.locus(size: 11, weight: .bold, design: .monospaced))
            Text(name).font(.locus(size: 7)).foregroundStyle(LocusTheme.muted)
        }
    }

    private func diagnosticLabel(_ name: String, _ value: String, healthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name.uppercased())
                .font(.locus(size: 7, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
            HStack(spacing: 4) {
                Circle()
                    .fill(healthy ? LocusTheme.success : LocusTheme.warning)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.locus(size: 8, design: .monospaced))
                    .lineLimit(1)
            }
        }
    }

    private func diagnosticTime(_ timestamp: Double?) -> String {
        guard let timestamp else { return "none recorded" }
        return Date(timeIntervalSince1970: timestamp).formatted(
            date: .abbreviated, time: .shortened
        )
    }

    private func memoryStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(.locus(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(LocusTheme.signalDeep))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.locus(size: 9, weight: .semibold))
                Text(detail).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .locusCard()
    }
}

private struct WorkspaceMemoryDraft: Identifiable {
    let id = UUID()
    var original: WorkspaceMemory?
    var title: String
    var content: String
    var tags: String
    var scope: AgentMemoryScope
    var kind: MemoryKind
    var confidence: Double
    var expires: Bool
    var validUntil: Date

    static var new: Self {
        .init(
            original: nil, title: "", content: "", tags: "", scope: .workspace,
            kind: .fact, confidence: 1, expires: false,
            validUntil: Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
        )
    }
    static func existing(_ memory: WorkspaceMemory) -> Self {
        .init(
            original: memory, title: memory.title, content: memory.content,
            tags: memory.tags.joined(separator: ", "), scope: memory.resolvedScope,
            kind: memory.resolvedKind, confidence: memory.resolvedConfidence,
            expires: memory.validUntil != nil,
            validUntil: memory.validUntil.map { Date(timeIntervalSince1970: $0) }
                ?? (Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date())
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
            Text(value.original == nil ? "Remember something" : "Edit memory")
                .font(.locus(size: 14, weight: .bold))
            Picker("Scope", selection: $value.scope) {
                ForEach(AgentMemoryScope.allCases) { Text($0.title).tag($0) }
            }
            Picker("Type", selection: $value.kind) {
                ForEach(MemoryKind.allCases) { Text($0.title).tag($0) }
            }
            Text(value.kind.explanation)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
            Text(scopeExplanation)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
            TextField("Title", text: $value.title)
            TextEditor(text: $value.content)
                .font(.locus(size: 10))
                .frame(minHeight: 180)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.line) }
            TextField("Tags", text: $value.tags, prompt: Text("decision, convention, fact"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Confidence · \(value.confidence, format: .percent.precision(.fractionLength(0)))")
                    .font(.locus(size: 9, weight: .semibold))
                Slider(value: $value.confidence, in: 0...1, step: 0.05)
                Text("Lower confidence makes this less likely to be recalled automatically.")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
            }
            Toggle("This memory expires", isOn: $value.expires)
            if value.expires {
                DatePicker("Valid until", selection: $value.validUntil, displayedComponents: .date)
            }
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
        .frame(width: 540, height: 600)
    }

    private var scopeExplanation: String {
        switch value.scope {
        case .personal: "Available to the primary agent across workspaces, including Just Chat."
        case .workspace: "Available only while this workspace is active; hidden from Just Chat."
        case .agent: "Available only to this agent profile."
        }
    }
}
