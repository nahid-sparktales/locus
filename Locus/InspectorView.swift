import AppKit
import SwiftUI

/// The right-hand inspector: a dynamic, closable tab shell around workspace
/// run state, files, instructions, terminal and checkpoints, with a drag
/// handle on its leading edge.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gitWorkspace: GitWorkspaceModel
    @EnvironmentObject private var workspaceFiles: WorkspaceFileModel
    @EnvironmentObject private var simulatorControl: SimulatorControlService

    var body: some View {
        VStack(spacing: 0) {
            if !model.openInspectorTabs.isEmpty {
                InspectorOpenTabBar()
                    .environmentObject(model)
                    // Browser and Terminal install native AppKit surfaces.
                    // Keep the title-bar controls above those siblings for
                    // hit-testing as well as drawing.
                    .zIndex(1)
            }

            Group {
                switch model.inspectorTab {
                case .plan:
                    InspectorPlanTab()
                case .changes:
                    InspectorChangesTab(gitWorkspace: gitWorkspace)
                case .files:
                    InspectorFilesTab(workspaceFiles: workspaceFiles)
                case .terminal:
                    InspectorTerminalTab()
                case .preview:
                    InspectorBrowserTab()
                case .simulator:
                    InspectorSimulatorTab(service: simulatorControl)
                case .notes:
                    InspectorNotesTab(
                        workspacePath: model.workspacePath,
                        sessionID: model.currentSessionID,
                        scope: model.settings.resolvedNotesScope
                    )
                    .id(NotesStore.storageIdentity(
                        workspacePath: model.workspacePath,
                        sessionID: model.currentSessionID,
                        scope: model.settings.resolvedNotesScope
                    ))
                case .checkpoints:
                    // Retained only as a persistence-compatible enum value.
                    // Every selection path redirects to CheckpointSheet.
                    EmptyView()
                case .runs:
                    InspectorRunsTab()
                case .agents:
                    InspectorAgentsTab()
                case .router:
                    InspectorRouterTab()
                case .proxies:
                    InspectorProxiesTab()
                }
            }
            .environmentObject(model)
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .locusSurface(
            .structural,
            radius: model.inspectorZoomed ? 12 : 0
        )
        .clipShape(RoundedRectangle(
            cornerRadius: model.inspectorZoomed ? 12 : 0,
            style: .continuous
        ))
        .overlay {
            if model.inspectorZoomed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            InspectorResizeHandle()
                .environmentObject(model)
        }
        .padding(model.inspectorZoomed ? 8 : 0)
        // The outer surface reaches into the hidden title-bar area. Match it
        // to the inspector when docked; only expanded mode needs the paper
        // color as a contrasting margin around its rounded panel.
        .background(model.inspectorZoomed ? LocusTheme.paper : Color.clear)
    }
}

// MARK: - Model router

struct InspectorRouterTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    controls
                    statusCard
                    if let decision = model.lastModelRoutingDecision {
                        scorecards(decision)
                    } else {
                        emptyScorecard
                    }
                }
                .padding(12)
            }
        }
        .onAppear {
            if model.lastModelRoutingDecision == nil {
                model.refreshModelRouterScorecard()
            }
        }
        .accessibilityIdentifier("inspector.router")
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: InspectorTab.router.symbol)
                .foregroundStyle(LocusTheme.signalDeep)
            Text("Model Router")
                .font(.locus(size: 12, weight: .bold))
            Spacer()
            Button {
                model.refreshModelRouterScorecard()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.locus())
            .help("Refresh scorecards")
            .accessibilityLabel("Refresh model scorecards")
            .accessibilityIdentifier("router.refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Choose a model for each solo message",
                isOn: Binding(
                    get: { model.settings.automaticModelRoutingEnabled },
                    set: model.setAutomaticModelRoutingEnabled
                )
            )
            .disabled(model.isBusy)
            .accessibilityIdentifier("router.enabled")

            Toggle(
                "Allow hosted accounts",
                isOn: Binding(
                    get: { model.settings.automaticModelRoutingAllowHosted },
                    set: model.setAutomaticModelRoutingAllowHosted
                )
            )
            .disabled(!model.settings.automaticModelRoutingEnabled || model.isBusy)
            .accessibilityIdentifier("router.allowHosted")

            Picker(
                "Priority",
                selection: Binding(
                    get: { model.settings.resolvedModelRoutingPolicy },
                    set: model.setModelRoutingPolicy
                )
            ) {
                ForEach(ModelRoutingPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("router.policy")

            Text("Hosted models are ineligible until separately allowed. Teams and automatic Solo delegation keep their own routing rules. Prompt text is never sent to the scorecard endpoint.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(model.settings.automaticModelRoutingEnabled
                    ? LocusTheme.success : LocusTheme.muted)
                .frame(width: 7, height: 7)
                .padding(.top, 3)
            Text(model.modelRouterMessage)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .locusCard(radius: 9)
        .accessibilityIdentifier("router.status")
    }

    @ViewBuilder
    private func scorecards(_ decision: ModelRoutingDecision) -> some View {
        HStack {
            Text("Scorecards")
                .font(.locus(size: 11, weight: .bold))
            Spacer()
            if decision.limitedData {
                Label("Learning", systemImage: "chart.dots.scatter")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
            }
        }
        if !decision.tags.isEmpty {
            Text("Task: \(decision.tags.joined(separator: " · "))")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
        }
        ForEach(decision.candidates) { card in
            scorecard(card)
        }
        Text("Efficiency uses local model download size as a footprint proxy. It is not a measured energy reading; hosted efficiency stays neutral without provider telemetry.")
            .font(.locus(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scorecard(_ card: ModelRoutingScorecard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.locus(size: 10, weight: .bold))
                        .lineLimit(2)
                    Text("\(card.sampleCount) samples · \(card.evaluationCount) evaluations")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 6)
                if card.selected {
                    Text("Selected")
                        .font(.locus(size: 8, weight: .bold))
                        .foregroundStyle(LocusTheme.signalDeep)
                } else if card.current {
                    Text("Current")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                Text(String(format: "%.0f", card.score))
                    .font(.locus(size: 15, weight: .bold))
            }
            ForEach(componentOrder, id: \.self) { component in
                let value = card.components[component] ?? 0
                HStack(spacing: 6) {
                    Text(componentTitle(component))
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 57, alignment: .leading)
                    ProgressView(value: value, total: 100)
                        .tint(card.selected ? LocusTheme.signalDeep : LocusTheme.muted)
                    Text(String(format: "%.0f", value))
                        .font(.locus(size: 8, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .locusCard(radius: 10)
        .overlay {
            if card.selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LocusTheme.signalDeep.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityIdentifier("router.scorecard.\(card.routeID)")
    }

    private var emptyScorecard: some View {
        Text("Scorecards appear here when the local agent is ready.")
            .font(.locus(size: 9))
            .foregroundStyle(LocusTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .locusCard(radius: 9)
    }

    private var componentOrder: [String] {
        ["quality", "reliability", "privacy", "latency", "cost", "efficiency"]
    }

    private func componentTitle(_ component: String) -> String {
        component == "efficiency" ? "Footprint" : component.capitalized
    }
}

// MARK: - Proxy manager

/// Advanced proxy management stays in the right inspector so routing and
/// health are visible while a chat is open. The Settings sheet still edits
/// the backward-compatible Default profile.
struct InspectorProxiesTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var modeRaw = ProxyMode.off.rawValue
    @State private var profiles: [ProxyProfile] = []
    @State private var selectedProfileID = ProxyProfile.primaryID
    @State private var activeProfileID = ProxyProfile.primaryID.uuidString
    @State private var strictMode = false
    @State private var autoFailover = false
    @State private var scopeRoutes: [String: String] = [:]
    @State private var workspaceRoutes: [String: String] = [:]
    @State private var providerRoutes: [String: String] = [:]
    @State private var authEnabledIDs: Set<UUID> = []
    @State private var passwordStoredIDs: Set<UUID> = []
    @State private var typedPasswords: [UUID: String] = [:]
    @State private var isTesting = false
    @State private var testOutcome: ProxyProbe.Outcome?

    private var mode: ProxyMode { ProxyMode(rawValue: modeRaw) ?? .off }
    private var selectedProfile: ProxyProfile? {
        profiles.first { $0.id == selectedProfileID }
    }
    private var workspaceKey: String {
        SessionSummary.canonicalWorkspacePath(model.workspacePath)
    }
    private var providerKey: String { model.settings.activeAccountID ?? "ollama" }
    private var providerTitle: String {
        model.activeAccount?.displayName ?? "Local Ollama"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connectionCard
                    if mode == .manual {
                        profileCard
                        safetyCard
                        routingCard
                        healthCard
                    }
                    coverageCard
                    actionBar
                }
                .padding(12)
            }
        }
        .onAppear(perform: load)
        .onChange(of: draftSignature) { testOutcome = nil }
        .accessibilityIdentifier("inspector.proxies")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: InspectorTab.proxies.symbol)
                .foregroundStyle(LocusTheme.signalDeep)
            Text("Proxy Manager")
                .font(.locus(size: 12, weight: .bold))
            Spacer()
            Circle()
                .fill(mode == .off ? LocusTheme.muted : LocusTheme.success)
                .frame(width: 7, height: 7)
            Text(headerStatus)
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Outbound traffic")
                .font(.locus(size: 10, weight: .bold))
            Picker("Route", selection: $modeRaw) {
                Text("Direct").tag(ProxyMode.off.rawValue)
                Text("System").tag(ProxyMode.system.rawValue)
                Text("Manual").tag(ProxyMode.manual.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("proxies.mode")

            Text(modeDetail)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if mode == .system, ProxyConfigurator.systemProxyUsesPAC() {
                Label(
                    "The app can follow the PAC file, but the Python agent cannot translate it. Use Manual to cover agent traffic.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Profiles")
                    .font(.locus(size: 10, weight: .bold))
                Spacer()
                Button { addProfile() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add proxy profile")
                Button { deleteSelectedProfile() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(selectedProfileID == ProxyProfile.primaryID)
                .help("Delete selected profile")
            }

            Picker("Profile", selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.name.isEmpty ? "Untitled proxy" : profile.name)
                        .tag(profile.id)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("proxies.profile")

            if selectedProfile != nil {
                if selectedProfileID != ProxyProfile.primaryID {
                    TextField("Profile name", text: profileBinding(\.name))
                        .textFieldStyle(.roundedBorder)
                    Toggle("Include in proxy pool", isOn: profileBinding(\.enabled))
                } else {
                    Text("Default profile")
                        .font(.locus(size: 9, weight: .semibold))
                }

                Picker("Type", selection: profileBinding(\.typeRaw)) {
                    Text("HTTP / HTTPS").tag(ProxyType.http.rawValue)
                    Text("SOCKS5").tag(ProxyType.socks5.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("proxies.type")

                TextField("Proxy host", text: profileBinding(\.host))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("proxies.host")
                TextField("Port", text: portBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("proxies.port")
                TextField("Bypass hosts (optional)", text: profileBinding(\.bypass))
                    .textFieldStyle(.roundedBorder)
                    .disabled(strictMode)
                    .accessibilityIdentifier("proxies.bypass")

                Toggle("Proxy requires sign-in", isOn: authBinding)
                    .accessibilityIdentifier("proxies.auth")
                if authEnabledIDs.contains(selectedProfileID) {
                    TextField("Username", text: profileBinding(\.username))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("proxies.username")
                    SecureField(
                        passwordStoredIDs.contains(selectedProfileID)
                            ? "Password (saved)" : "Password",
                        text: passwordBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("proxies.password")
                }
            }

            HStack {
                Text("Default route")
                    .font(.locus(size: 9))
                Spacer()
                profilePicker(selection: $activeProfileID, inheritTitle: nil)
                    .frame(maxWidth: 150)
            }

            if let error = draftError {
                Text(error)
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proxies.error")
            }
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Safety & failover")
                .font(.locus(size: 10, weight: .bold))
            Toggle("Strict tunnel (block direct fallback)", isOn: $strictMode)
                .accessibilityIdentifier("proxies.strict")
            Text("Only loopback, the local agent, and Ollama stay direct. Custom bypass hosts are ignored while strict mode is on.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Health-ranked automatic failover", isOn: $autoFailover)
                .accessibilityIdentifier("proxies.failover")
            Text("Locus checks enabled profiles every minute, keeps the assigned route when healthy, and otherwise selects the fastest healthy proxy. If none are healthy, traffic is blocked.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split routing")
                .font(.locus(size: 10, weight: .bold))
            Text("An assignment overrides the default route. Provider overrides workspace; traffic class is strongest.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ProxyTrafficScope.allCases.filter { $0 != .app }) { scope in
                routeRow(
                    scope.title,
                    selection: routeBinding(scope: scope)
                )
            }

            Divider()
            routeRow(
                "This workspace",
                selection: workspaceRouteBinding
            )
            Text(URL(fileURLWithPath: workspaceKey).lastPathComponent)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)

            routeRow(providerTitle, selection: providerRouteBinding)
            Text("The provider route applies when this account is active.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pool health")
                    .font(.locus(size: 10, weight: .bold))
                Spacer()
                Button(model.isCheckingProxyHealth ? "Checking…" : "Check all") {
                    model.refreshProxyHealth()
                }
                .disabled(model.isCheckingProxyHealth || draftError != nil)
                .accessibilityIdentifier("proxies.healthCheck")
            }
            Text(model.proxyHealthMessage)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.proxyHealthRecords) { record in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: record.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(record.ok ? LocusTheme.success : LocusTheme.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.profileName)
                                .font(.locus(size: 9, weight: .semibold))
                            Spacer()
                            if let latency = record.latencyMilliseconds {
                                Text("\(latency) ms")
                                    .font(.locus(size: 8))
                                    .monospacedDigit()
                            }
                        }
                        Text(record.message)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let location = record.location, !location.isEmpty {
                            Text("Location: \(location)")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                }
            }
        }
        .padding(11)
        .locusCard(radius: 10)
    }

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Coverage")
                .font(.locus(size: 10, weight: .bold))
            Label("App requests and model providers", systemImage: "checkmark.circle.fill")
            Label("Agent web traffic, extensions, and Git", systemImage: "checkmark.circle.fill")
            Label("Built-in browser and model downloads", systemImage: "checkmark.circle.fill")
            Label("Local agent and Ollama stay direct", systemImage: "arrow.triangle.turn.up.right.circle")
            Text("This controls Locus traffic, not other Mac apps. SOCKS5 uses remote DNS. Health checks show the external exit address and never use a direct fallback.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.locus(size: 9))
        .foregroundStyle(LocusTheme.ink)
        .padding(11)
        .locusCard(radius: 10)
    }

    private var actionBar: some View {
        HStack {
            Button(isTesting ? "Testing…" : "Test selected") { testSelectedProfile() }
                .disabled(isTesting || mode != .manual || draftError != nil)
                .accessibilityIdentifier("proxies.test")
            if let outcome = testOutcome {
                Text(outcome.message)
                    .font(.locus(size: 8))
                    .foregroundStyle(outcome.ok ? LocusTheme.success : LocusTheme.coral)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Apply") { apply() }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(draftError != nil || model.isBusy)
                .accessibilityIdentifier("proxies.apply")
        }
    }

    private func routeRow(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.locus(size: 9))
            Spacer()
            profilePicker(selection: selection, inheritTitle: "Default")
                .frame(maxWidth: 150)
        }
    }

    private func profilePicker(
        selection: Binding<String>,
        inheritTitle: String?
    ) -> some View {
        Picker("Proxy", selection: selection) {
            if let inheritTitle { Text(inheritTitle).tag("") }
            ForEach(profiles) { profile in
                Text(profile.name.isEmpty ? "Untitled proxy" : profile.name)
                    .tag(profile.id.uuidString)
            }
        }
        .labelsHidden()
    }

    private var headerStatus: String {
        switch mode {
        case .off: "Direct"
        case .system: "System"
        case .manual:
            selectedProfile.map { $0.resolvedType.rawValue.uppercased() } ?? "Manual"
        }
    }

    private var modeDetail: String {
        switch mode {
        case .off: "Connections leave directly."
        case .system: "The app follows macOS proxy settings; the agent receives settings that can be expressed as proxy environment variables."
        case .manual: "Named profiles can be assigned by traffic class, workspace, or provider account."
        }
    }

    private var draftError: String? {
        guard mode == .manual else { return nil }
        guard !profiles.isEmpty else { return "Add at least one proxy profile." }
        let enabled = profiles.filter(\.enabled)
        for profile in enabled {
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Every enabled profile needs a name."
            }
            if ProxyConfigurator.normalizedHost(profile.host).isEmpty
                || AppSettings.clampProxyPort(profile.port) == nil {
                return "\(profile.name) needs a host and a port from 1 to 65535."
            }
            if authEnabledIDs.contains(profile.id) {
                if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(profile.name) sign-in needs a username."
                }
                if !passwordStoredIDs.contains(profile.id)
                    && (typedPasswords[profile.id] ?? "").isEmpty {
                    return "\(profile.name) sign-in needs a password."
                }
            }
        }
        guard let activeID = UUID(uuidString: activeProfileID),
              enabled.contains(where: { $0.id == activeID })
        else { return "Choose an enabled Default route." }
        let assigned = Array(scopeRoutes.values)
            + Array(workspaceRoutes.values)
            + Array(providerRoutes.values)
        let enabledIDs = Set(enabled.map { $0.id.uuidString })
        if let invalid = assigned.first(where: { !$0.isEmpty && !enabledIDs.contains($0) }) {
            let name = profiles.first { $0.id.uuidString == invalid }?.name ?? "A route"
            return "\(name) is assigned but not enabled."
        }
        return nil
    }

    private var draftSignature: String {
        let encodedProfiles = (try? JSONEncoder().encode(profiles)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? ""
        return [
            modeRaw, encodedProfiles, activeProfileID, strictMode ? "1" : "0",
            autoFailover ? "1" : "0", scopeRoutes.description,
            workspaceRoutes.description, providerRoutes.description,
            authEnabledIDs.map(\.uuidString).sorted().joined(separator: ","),
            typedPasswords.description,
        ].joined(separator: "\u{1F}")
    }

    private func profileBinding<Value>(
        _ keyPath: WritableKeyPath<ProxyProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let profile = selectedProfile else {
                    preconditionFailure("A selected proxy profile must exist")
                }
                return profile[keyPath: keyPath]
            },
            set: { value in
                guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
                else { return }
                profiles[index][keyPath: keyPath] = value
            }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { selectedProfile?.port.map(String.init) ?? "" },
            set: { value in
                guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
                else { return }
                profiles[index].port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
    }

    private var authBinding: Binding<Bool> {
        Binding(
            get: { authEnabledIDs.contains(selectedProfileID) },
            set: { enabled in
                if enabled {
                    authEnabledIDs.insert(selectedProfileID)
                } else {
                    authEnabledIDs.remove(selectedProfileID)
                    if let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
                        profiles[index].username = ""
                    }
                    typedPasswords[selectedProfileID] = ""
                }
            }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { typedPasswords[selectedProfileID] ?? "" },
            set: { typedPasswords[selectedProfileID] = $0 }
        )
    }

    private func routeBinding(scope: ProxyTrafficScope) -> Binding<String> {
        Binding(
            get: { scopeRoutes[scope.rawValue] ?? "" },
            set: { value in
                if value.isEmpty { scopeRoutes.removeValue(forKey: scope.rawValue) }
                else { scopeRoutes[scope.rawValue] = value }
            }
        )
    }

    private var workspaceRouteBinding: Binding<String> {
        Binding(
            get: { workspaceRoutes[workspaceKey] ?? "" },
            set: { value in
                if value.isEmpty { workspaceRoutes.removeValue(forKey: workspaceKey) }
                else { workspaceRoutes[workspaceKey] = value }
            }
        )
    }

    private var providerRouteBinding: Binding<String> {
        Binding(
            get: { providerRoutes[providerKey] ?? "" },
            set: { value in
                if value.isEmpty { providerRoutes.removeValue(forKey: providerKey) }
                else { providerRoutes[providerKey] = value }
            }
        )
    }

    private func load() {
        let settings = model.settings
        modeRaw = settings.proxyModeRaw
        profiles = settings.allProxyProfiles
        selectedProfileID = profiles.first?.id ?? ProxyProfile.primaryID
        activeProfileID = settings.proxyActiveProfileID
        if !profiles.contains(where: { $0.id.uuidString == activeProfileID }) {
            activeProfileID = profiles.first?.id.uuidString ?? ProxyProfile.primaryID.uuidString
        }
        strictMode = settings.proxyStrictModeEnabled
        autoFailover = settings.proxyAutoFailoverEnabled
        scopeRoutes = settings.proxyScopeProfileIDs
        workspaceRoutes = settings.proxyWorkspaceProfileIDs
        providerRoutes = settings.proxyProviderProfileIDs
        authEnabledIDs = Set(profiles.filter { !$0.username.isEmpty }.map(\.id))
        passwordStoredIDs = model.persistenceEnabled
            ? Set(profiles.compactMap { profile in
                CredentialStore.proxyPassword(profileID: profile.id) == nil ? nil : profile.id
            }) : []
        typedPasswords = [:]
        testOutcome = nil
    }

    private func addProfile() {
        let number = profiles.count + 1
        let profile = ProxyProfile(name: "Proxy \(number)")
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    private func deleteSelectedProfile() {
        guard selectedProfileID != ProxyProfile.primaryID else { return }
        let raw = selectedProfileID.uuidString
        profiles.removeAll { $0.id == selectedProfileID }
        scopeRoutes = scopeRoutes.filter { $0.value != raw }
        workspaceRoutes = workspaceRoutes.filter { $0.value != raw }
        providerRoutes = providerRoutes.filter { $0.value != raw }
        authEnabledIDs.remove(selectedProfileID)
        typedPasswords.removeValue(forKey: selectedProfileID)
        passwordStoredIDs.remove(selectedProfileID)
        if activeProfileID == raw {
            activeProfileID = ProxyProfile.primaryID.uuidString
        }
        selectedProfileID = profiles.first?.id ?? ProxyProfile.primaryID
    }

    private func normalized(_ profile: ProxyProfile) -> ProxyProfile {
        var result = profile
        result.name = result.id == ProxyProfile.primaryID
            ? "Default" : result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = ProxyConfigurator.normalizedHost(result.host)
        result.port = AppSettings.clampProxyPort(result.port)
        result.username = authEnabledIDs.contains(result.id)
            ? result.username.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if result.id == ProxyProfile.primaryID { result.enabled = true }
        return result
    }

    private func proxySettingsCandidate() -> AppSettings {
        var saved = model.settings
        let normalizedProfiles = profiles.map(normalized)
        let primary = normalizedProfiles.first { $0.id == ProxyProfile.primaryID }
            ?? ProxyProfile(id: ProxyProfile.primaryID, name: "Default")
        saved.proxyModeRaw = modeRaw
        saved.proxyTypeRaw = primary.typeRaw
        saved.proxyHost = primary.host
        saved.proxyPort = primary.port
        saved.proxyBypass = primary.bypass
        saved.proxyUsername = primary.username
        saved.proxyProfiles = normalizedProfiles.filter { $0.id != ProxyProfile.primaryID }
        saved.proxyActiveProfileID = activeProfileID
        saved.proxyStrictModeEnabled = strictMode
        saved.proxyAutoFailoverEnabled = autoFailover
        saved.proxyScopeProfileIDs = scopeRoutes.filter { !$0.value.isEmpty }
        saved.proxyWorkspaceProfileIDs = workspaceRoutes.filter { !$0.value.isEmpty }
        saved.proxyProviderProfileIDs = providerRoutes.filter { !$0.value.isEmpty }
        return saved
    }

    private func apply() {
        let saved = proxySettingsCandidate()
        var credentialChanged = false
        if model.persistenceEnabled {
            for profile in profiles {
                let stored = CredentialStore.proxyPassword(profileID: profile.id)
                if !authEnabledIDs.contains(profile.id) {
                    if stored != nil {
                        credentialChanged = CredentialStore.setProxyPassword(
                            "", profileID: profile.id
                        ) || credentialChanged
                    }
                } else if let typed = typedPasswords[profile.id], !typed.isEmpty,
                          typed != stored {
                    credentialChanged = CredentialStore.setProxyPassword(
                        typed, profileID: profile.id
                    ) || credentialChanged
                }
            }
        }
        model.applySettings(saved, proxyCredentialChanged: credentialChanged)
        load()
    }

    private func testSelectedProfile() {
        let candidate = proxySettingsCandidate()
        guard let profile = candidate.allProxyProfiles.first(where: { $0.id == selectedProfileID })
        else { return }
        let typed = typedPasswords[profile.id] ?? ""
        let password = typed.isEmpty
            ? CredentialStore.proxyPassword(profileID: profile.id) : typed
        guard let resolved = ProxyConfigurator.resolved(
            settings: candidate,
            profile: profile,
            password: password,
            ollamaHost: nil
        ) else { return }
        let base = model.activeAccount
            .map { RemoteEndpointTester.normalizeBaseURL($0.resolvedBaseURL) }
            .flatMap(URL.init(string:))
            .flatMap { OllamaRuntime.isLoopback($0) ? nil : $0 }
        let target = base ?? URL(string: "https://huggingface.co")!
        isTesting = true
        testOutcome = nil
        Task {
            testOutcome = await ProxyProbe.test(proxy: resolved, target: target)
            isTesting = false
        }
    }
}

/// Only panels the user has opened appear here. The rail and overflow menu are
/// launchers; this bar is the durable, ordered workspace for switching and
/// closing panels without the permanent icon row competing for space.
private struct InspectorOpenTabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                tabItems
            }
            .onAppear {
                proxy.scrollTo(model.inspectorTab.id, anchor: .center)
            }
            .onChange(of: model.inspectorTab) { _, tab in
                proxy.scrollTo(tab.id, anchor: .center)
            }
        }
        .frame(height: 31)
        .clipped()
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.tabBar")
    }

    private var tabItems: some View {
        HStack(spacing: 3) {
            ForEach(model.openInspectorTabs) { tab in
                InspectorOpenTabItem(tab: tab, width: tabWidth(tab))
                    .environmentObject(model)
                    .id(tab.id)
            }
        }
        .padding(.horizontal, 7)
    }

    private func tabWidth(_ tab: InspectorTab) -> CGFloat {
        let labelWidth = ceil((tab.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).width)
        let badgeWidth = InspectorOpenTabItem.reservedBadgeWidth(for: tab)
        // Text, optional status, and close control each get a stable slot. This
        // avoids the loose label/X spacing that made the old row feel uneven.
        return min(104, max(55, labelWidth + badgeWidth + 35))
    }

}

/// Kept as its own identity-bearing view so rebuilding the selected panel can
/// never leave another tab's click closure attached to this tab's label.
private struct InspectorOpenTabItem: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab
    let width: CGFloat
    @State private var isHovering = false

    private var selected: Bool { model.inspectorTab == tab }
    private var labelWidth: CGFloat {
        ceil((tab.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).width)
    }

    static func reservedBadgeWidth(for tab: InspectorTab) -> CGFloat {
        tab == .changes ? 18 : (tab == .plan ? 7 : 0)
    }

    var body: some View {
        HStack(spacing: 3) {
            InspectorTabActivationButton(
                title: tab.title,
                selected: selected,
                accessibilityIdentifier: "inspector.tab.\(tab.rawValue)",
                action: focus
            )
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)

            if Self.reservedBadgeWidth(for: tab) > 0 {
                InspectorTextTabBadge(tab: tab)
                    .environmentObject(model)
                    .frame(width: Self.reservedBadgeWidth(for: tab))
                    .allowsHitTesting(false)
            }

            InspectorTabCloseButton(tab: tab, emphasized: selected || isHovering)
                .environmentObject(model)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: width, height: 28)
        .background(
            isHovering ? LocusTheme.white.opacity(selected ? 0.28 : 0.38) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if selected {
                Capsule()
                    .fill(LocusTheme.ink)
                    .frame(height: 2)
                    .frame(width: min(labelWidth + 2, width - 30))
                    .padding(.leading, 8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private func focus() {
        guard !selected || model.inspectorCollapsed else { return }
        model.selectInspectorTab(tab)
    }
}

/// The close affordance stays quiet until its tab is active or hovered, but
/// its hit target never changes size. Tabs therefore remain calm and do not
/// shift as the pointer moves across the bar.
private struct InspectorTabCloseButton: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab
    let emphasized: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            model.closeInspectorTab(tab)
        } label: {
            Image(systemName: "xmark")
                .font(.locus(size: 6.5, weight: .bold))
                .foregroundStyle(LocusTheme.inkSoft)
                .frame(width: 16, height: 18)
                .background(isHovering ? LocusTheme.ink.opacity(0.08) : Color.clear)
                .clipShape(Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .opacity(emphasized || isHovering ? 0.9 : 0.42)
        .onHover { isHovering = $0 }
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title) tab")
        .accessibilityIdentifier("inspector.tab.close.\(tab.rawValue)")
    }
}

/// A title-bar control must accept the first mouse event even when a native
/// editor, web view, or PTY currently owns first responder. SwiftUI's macOS
/// Button does not guarantee that when it is moved into the hidden title-bar
/// safe area, which makes the first tab switch appear to do nothing.
private struct InspectorTabActivationButton: NSViewRepresentable {
    let title: String
    let selected: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    final class FirstMouseButton: NSButton {
        var mouseDownAction: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Browser and Terminal can change first responder during the same
            // event transaction. Dispatch from the control that was hit
            // instead of relying on mouse-up tracking to finish later.
            mouseDownAction?()
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> FirstMouseButton {
        let button = FirstMouseButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.activate)
        )
        button.isBordered = false
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setButtonType(.momentaryChange)
        button.mouseDownAction = context.coordinator.activate
        return button
    }

    func updateNSView(_ button: FirstMouseButton, context: Context) {
        context.coordinator.action = action
        // The selected-state rebuild can give an existing NSButton a fresh
        // representable coordinator. NSControl does not retain its target, so
        // refresh both pieces instead of leaving the button pointed at the
        // coordinator from the previous panel transaction.
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        button.mouseDownAction = context.coordinator.activate
        button.title = title
        let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium)
        let titleColor = InspectorTabAppearance.titleColor(
            colorScheme: context.environment.colorScheme,
            selected: selected
        )
        // contentTintColor does not reliably color an NSButton title in the
        // dark title-bar material. An attributed title keeps every open tab
        // white instead of only the selected or hovered one.
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: titleColor]
        )
        button.contentTintColor = titleColor
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel("\(title) inspector tab")
        button.setAccessibilityValue(selected ? "Selected" : "Not selected")
    }
}

enum InspectorTabAppearance {
    static func titleColor(colorScheme: ColorScheme, selected: Bool) -> NSColor {
        if colorScheme == .dark { return .white }
        return selected ? .labelColor : .secondaryLabelColor.withAlphaComponent(0.86)
    }
}

/// Compact attention state for text tabs. Destination symbols stay on the
/// vertical rail; the top bar uses only labels, badges, and close controls.
private struct InspectorTextTabBadge: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gitWorkspace: GitWorkspaceModel
    let tab: InspectorTab

    @ViewBuilder
    var body: some View {
        if tab == .changes, gitWorkspace.changedFileCount > 0 {
            Text(gitWorkspace.changedFileCount > 99 ? "99+" : "\(gitWorkspace.changedFileCount)")
                .font(.locus(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(minHeight: 16)
                .background(gitWorkspace.changesHaveUnseenUpdate ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .accessibilityHidden(true)
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// Shared empty state for inspector tabs.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.locus(size: 23))
                .foregroundStyle(LocusTheme.muted)
            Text(title)
                .font(.locus(size: 11, weight: .bold))
            Text(message)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

/// Attention badge on the rail's icons, so a collapsed inspector keeps
/// asking for eyes exactly the way an open panel does.
struct InspectorTabBadge: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gitWorkspace: GitWorkspaceModel
    let tab: InspectorTab

    var body: some View {
        if tab == .changes, gitWorkspace.changedFileCount > 0 {
            // Coral only while the change is still unseen; once you have opened
            // the tab the count stays but stops asking for attention.
            let unseen = gitWorkspace.changesHaveUnseenUpdate
            Text(gitWorkspace.changedFileCount > 99 ? "99+" : "\(gitWorkspace.changedFileCount)")
                .font(.locus(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(minHeight: 16)
                .background(unseen ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .offset(x: 9, y: -5)
                .accessibilityElement()
                .accessibilityLabel(
                    unseen
                        ? "\(gitWorkspace.changedFileCount) changed files, new since you last looked"
                        : "\(gitWorkspace.changedFileCount) changed files"
                )
                .accessibilityIdentifier("inspector.tab.changes.badge")
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .offset(x: 5, y: -3)
                .accessibilityElement()
                .accessibilityLabel("Plan updated")
                .accessibilityIdentifier("inspector.tab.plan.badge")
        }
    }
}

/// Drag target on the inspector's leading divider.
private struct InspectorResizeHandle: View {
    @EnvironmentObject private var model: AppModel
    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .frame(width: 1)
            .overlay {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))

                    if model.inspectorZoomed {
                        Capsule()
                            .fill(
                                LocusTheme.ink.opacity(isHovering ? 0.52 : 0.28)
                            )
                            .frame(width: 3, height: 44)
                    }
                }
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        isHovering = inside
                        // `.set()` rather than push/pop: an unbalanced pair is
                        // the classic way to leave the cursor stuck.
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // Accumulate from a captured start width so the
                                // panel cannot drift over a long drag. Zoomed,
                                // the panel fills the remainder, so the same
                                // divider drags the chat column instead —
                                // rightward widens chat in both readings.
                                if model.inspectorZoomed {
                                    let start = startWidth ?? model.zoomedChatWidth
                                    if startWidth == nil { startWidth = start }
                                    model.setZoomedChatWidth(start + value.translation.width)
                                } else {
                                    let start = startWidth ?? model.inspectorWidth
                                    if startWidth == nil { startWidth = start }
                                    model.setInspectorWidth(start - value.translation.width)
                                }
                            }
                            .onEnded { _ in
                                startWidth = nil
                                if model.inspectorZoomed {
                                    model.commitZoomedChatWidth()
                                } else {
                                    model.commitInspectorWidth()
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        if model.inspectorZoomed {
                            model.setZoomedChatWidth(AppSettings.defaultZoomedChatWidth)
                            model.commitZoomedChatWidth()
                        } else {
                            model.setInspectorWidth(AppSettings.defaultInspectorWidth)
                            model.commitInspectorWidth()
                        }
                    }
                    .accessibilityRepresentation {
                        Slider(
                            value: Binding(
                                get: {
                                    Double(
                                        model.inspectorZoomed
                                            ? model.zoomedChatWidth
                                            : model.inspectorWidth
                                    )
                                },
                                set: { value in
                                    if model.inspectorZoomed {
                                        model.setZoomedChatWidth(CGFloat(value))
                                        model.commitZoomedChatWidth()
                                    } else {
                                        model.setInspectorWidth(CGFloat(value))
                                        model.commitInspectorWidth()
                                    }
                                }
                            ),
                            in: model.inspectorZoomed
                                ? AppSettings.minimumZoomedChatWidth...AppSettings.maximumZoomedChatWidth
                                : AppSettings.minimumInspectorWidth...AppSettings.maximumInspectorWidth
                        ) {
                            Text(
                                model.inspectorZoomed
                                    ? "Expanded panel width"
                                    : "Inspector width"
                            )
                        }
                        .accessibilityHint("Adjust the panel width. Double-click the divider to reset it.")
                        .accessibilityIdentifier("inspector.resizeHandle")
                    }
            }
    }
}

private enum RunsStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Any status"
        case .active: "Active"
        case .attention: "Needs attention"
        case .finished: "Finished"
        }
    }

    func includes(_ run: OrchestrationRun) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            ["queued", "dispatching", "running", "reviewing"].contains(run.state)
        case .attention:
            ["waiting_permission", "waiting_computer", "waiting_dispatch_approval",
             "paused", "interrupted", "failed"].contains(run.state)
        case .finished:
            TeamRunState(rawValue: run.state)?.isTerminal == true
        }
    }
}

struct InspectorRunsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var runs: OrchestrationRunsModel
    @EnvironmentObject private var gitWorkspace: GitWorkspaceModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @State private var scope: RunScope = .all
    @State private var statusFilter: RunsStatusFilter = .all
    @State private var runSearch = ""
    @State private var showingRunDetail = false
    @State private var detailRunID: String?
    @State private var viewMode = "overview"
    @State private var filter = ""
    @State private var draftPlan: DispatchPlan?
    @State private var showTechnicalLog = false
    @State private var requestExpanded = false
    @State private var telemetryContentRunID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let plan = draftPlan, model.pendingDispatchPlan != nil {
                dispatchEditor(plan)
            } else if showingRunDetail,
                      let detailRunID,
                      let run = model.runRecord(for: detailRunID) {
                // A different run is a different document: re-identifying the
                // subtree resets scroll, "Show N more" lists, and disclosure
                // groups instead of carrying one run's expansions into another.
                runBody(run)
                    .id(run.id)
            } else if showingRunDetail {
                ProgressView("Loading run…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runList
            }
        }
        .task(id: model.currentSessionID) {
            if !runs.isLoadingOrchestrationRuns {
                await runs.refreshOrchestrationRuns()
            }
        }
        .onChange(of: model.pendingDispatchPlan) { _, value in draftPlan = value }
        // Tab-level state, so a run switch would otherwise carry it over and
        // open the next run's request pre-expanded.
        .onChange(of: detailRunID) { requestExpanded = false }
        .task(id: model.runsNavigationRequest?.id) {
            guard let request = model.runsNavigationRequest else {
                showingRunDetail = false
                detailRunID = nil
                return
            }
            detailRunID = request.runID
            await runs.loadOrchestrationRun(request.runID)
            if let run = model.runRecord(for: request.runID) {
                scope = run.isSoloSwarm ? .soloSwarm : (run.runKind == "team" ? .teams : .all)
                showingRunDetail = true
            }
        }
        .onAppear { draftPlan = model.pendingDispatchPlan }
        .confirmationDialog(
            "Include visible content in this trace?",
            isPresented: Binding(
                get: { telemetryContentRunID != nil },
                set: { if !$0 { sendMetadataInsteadOfContent() } }
            ),
            titleVisibility: .visible
        ) {
            if let runID = telemetryContentRunID {
                Button("Send Content Trace") {
                    telemetryContentRunID = nil
                    Task { await model.exportRunToOTLP(runID, includeContent: true) }
                }
            }
            Button("Send Metadata Only", role: .cancel) {
                sendMetadataInsteadOfContent()
            }
        } message: {
            Text("This one export may contain prompts, visible responses, and tool content. Credentials and authorization values remain excluded. Dismissing sends metadata only.")
        }
    }

    private func sendMetadataInsteadOfContent() {
        guard let runID = telemetryContentRunID else { return }
        telemetryContentRunID = nil
        Task { await model.exportRunToOTLP(runID) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: InspectorTab.runs.symbol)
                    .foregroundStyle(LocusTheme.signalDeep)
                    // Decoration beside the panel's own title: unhidden, it is
                    // exposed with its raw SF Symbol name as its label.
                    .accessibilityHidden(true)
                Text("RUNS")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Button {
                    Task { await runs.refreshOrchestrationRuns() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.locus())
                    .help("Refresh run history")
            }
            Picker("Run type", selection: Binding(
                get: { scope },
                set: { newScope in
                    scope = newScope
                    showingRunDetail = false
                    detailRunID = nil
                }
            )) {
                ForEach(RunScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("runs.scope")

            if scope == .soloSwarm {
                adaptiveSoloInfo
            }

            if !showingRunDetail {
                HStack(spacing: 7) {
                    TextField("Search runs", text: $runSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("runs.search")
                    Menu {
                        ForEach(RunsStatusFilter.allCases) { item in
                            Button {
                                statusFilter = item
                            } label: {
                                Label(item.title, systemImage: statusFilter == item ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help(statusFilter.title)
                    .accessibilityLabel("Filter by status")
                    .accessibilityValue(statusFilter.title)
                    .accessibilityIdentifier("runs.statusFilter")
                }
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var runPickerRuns: [OrchestrationRun] {
        AppModel.orchestrationPickerRuns(
            runs.orchestrationRuns,
            selected: runs.selectedOrchestrationRun
        )
    }

    private func runTitle(_ run: OrchestrationRun) -> String {
        if let name = run.teamName?.nilIfEmpty { return name }
        if run.isSoloSwarm { return "Solo run" }
        switch run.runKind {
        case "solo": return "Solo run"
        case "evaluation": return "Evaluation"
        case "verification": return "Verification"
        case "memory_review": return "Memory review"
        default: return "Team run"
        }
    }

    private func runCategoryTitle(_ run: OrchestrationRun) -> String {
        if run.isSoloSwarm { return "Solo" }
        if run.runKind == "team" { return "Team" }
        return (run.runKind ?? "solo")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func runSymbol(_ run: OrchestrationRun) -> String {
        if run.isSoloSwarm { return "circle.hexagongrid.fill" }
        if run.runKind == "team" { return "person.2.fill" }
        return "person.fill"
    }

    private func runStateColor(_ run: OrchestrationRun) -> Color {
        switch TeamRunState(rawValue: run.state) {
        case .completed: LocusTheme.success
        case .failed, .interrupted, .cancelled, .discarded: LocusTheme.coral
        case .paused, .waitingComputer, .waitingPermission, .waitingDispatchApproval:
            LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }

    private func runProgress(_ run: OrchestrationRun) -> String? {
        let total = run.jobCount ?? 0
        guard total > 0 else { return nil }
        let unit = run.isSoloSwarm ? "workers" : "jobs"
        return "\(run.completedJobCount ?? 0)/\(total) \(unit)"
    }

    private var filteredRuns: [OrchestrationRun] {
        let query = runSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runPickerRuns
            .filter { scope.includes($0) && statusFilter.includes($0) }
            .filter { run in
                query.isEmpty || [runTitle(run), run.request, run.state, run.runKind ?? ""]
                    .joined(separator: " ").lowercased().contains(query)
            }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private var adaptiveSoloInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Solo delegates automatically", systemImage: "person.2")
                .font(.locus(size: 9, weight: .semibold))
            Text("When parallel work would help, temporary workers share the selected model and inherit the current tools and permission mode.")
                .font(.locus(size: 8))
                // `muted` measures ~4.3:1 against this tinted card once the
                // text is actually drawn, and fails outright on a 1x display
                // where there is no subpixel coverage to help it.
                .foregroundStyle(LocusTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("runs.solo.adaptiveDelegation")
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.signal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.24), lineWidth: 1)
        }
    }

    private var runList: some View {
        Group {
            if runs.isLoadingOrchestrationRuns && runPickerRuns.isEmpty {
                ProgressView("Loading runs…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRuns.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: scope == .soloSwarm
                        ? "circle.hexagongrid" : "clock.arrow.circlepath")
                        .font(.locus(size: 24))
                        .foregroundStyle(LocusTheme.muted)
                    Text(scope == .soloSwarm ? "No Solo runs yet" : "No matching runs")
                        .font(.locus(size: 11, weight: .bold))
                    Text(scope == .soloSwarm
                        ? "Send a Solo Work, Plan, or Grill request. Locus delegates automatically when parallel investigation would help."
                        : "Try another run type, status, or search term.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(scope == .soloSwarm
                    ? "runs.soloSwarm.empty" : "runs.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRuns) { run in
                            runListRow(run)
                        }
                    }
                    .padding(12)
                }
                .accessibilityIdentifier("runs.list")
            }
        }
    }

    private func runListRow(_ run: OrchestrationRun) -> some View {
        Button {
            detailRunID = run.id
            viewMode = "overview"
            filter = ""
            showingRunDetail = true
            Task { await runs.loadOrchestrationRun(run.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: runSymbol(run))
                        .foregroundStyle(runStateColor(run))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(runTitle(run))
                                .font(.locus(size: 10, weight: .bold))
                                .lineLimit(1)
                            if run.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        Text(run.request.isEmpty ? "No request was recorded." : run.request)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(run.state.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.locus(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(runStateColor(run))
                }
                HStack(spacing: 5) {
                    Text(runCategoryTitle(run))
                    Text("·")
                    Text(Date(timeIntervalSince1970: run.updatedAt), style: .relative)
                    if let progress = runProgress(run) {
                        Text("·")
                        Text(progress)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line) }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .accessibilityIdentifier("runs.row.\(run.id)")
    }

    private func runBody(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showingRunDetail = false
                    detailRunID = nil
                } label: {
                    Label(scope.title, systemImage: "chevron.left")
                }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.back")
                Spacer()
                Text(runCategoryTitle(run).uppercased())
                    .font(.locus(size: 7, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 31)
            .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
            runSummary(run)
            Picker("View", selection: $viewMode) {
                Text("Overview")
                    .accessibilityIdentifier("runs.view.overview")
                    .tag("overview")
                Text("Activity")
                    .accessibilityIdentifier("runs.view.activity")
                    .tag("activity")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if viewMode == "overview" {
                if run.isSoloSwarm {
                    soloSwarmOverview(run)
                } else if run.runKind == "team" {
                    overview(run)
                } else {
                    soloOverview(run)
                }
            } else {
                activity(run)
            }
        }
    }

    private func runSummary(_ run: OrchestrationRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runTitle(run))
                        .font(.locus(size: 11, weight: .bold))
                    Text(runStateTitle(run))
                        .font(.locus(size: 8, design: .monospaced))
                        // The darkest pixel `muted` glyphs draw at 1x is
                        // #72746B — about 4.0:1 against the panel, under the
                        // audit's 4.5:1 floor. Same class as the delegation
                        // card fixed for #46, so every small text run on this
                        // surface uses the secondary role instead.
                        .foregroundStyle(LocusTheme.textSecondary)
                        .accessibilityIdentifier("runs.state")
                }
                Spacer()
                runPrimaryAction(run)
                runActions(run)
            }
            let presentation = model.teamRunPresentation(for: run.id, durable: run)
            if let reason = run.recoveryReason, presentation.canRecover {
                Label(reason, systemImage: "arrow.clockwise.circle.fill")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let task = model.activeTaskRecord, task.id == run.taskID {
                HStack(spacing: 7) {
                    Button("Review & Land") { landingFlow.prepareReviewAndLand() }
                        .disabled(model.isBusy || !landingFlow.taskHasChanges)
                    Button("Copy Patch") { model.copyActiveTaskPatch() }
                        .disabled(model.isBusy || !landingFlow.taskHasChanges)
                    Menu {
                        Button("Open Checkout") { model.openActiveTaskCheckout() }
                        Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                }
                .buttonStyle(.locus())
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(LocusTheme.paperDeep.opacity(0.5))
    }

    @ViewBuilder
    private func runPrimaryAction(_ run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        if presentation.canStop, run.runKind == "solo" {
            Button("Stop") { model.cancelOrchestration(run.id) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityIdentifier("runs.stop")
        } else if run.runKind == "solo",
                  ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
            Button("Retry") { model.retryRun(run) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.retry")
        } else if presentation.canRecover, run.runKind == "team" {
            if run.checkpoint?.state["fallback_action"]?.string == "run_with_locus" {
                Button("Run with Locus") { model.runOrchestrationWithLocus(run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.runWithLocus")
            } else {
                Button("Resume") { model.resumeOrchestration(run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.resume")
            }
        } else if presentation.canPause, run.runKind == "team" {
            Button("Pause") { model.pauseOrchestration(run.id) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.pause")
        }
    }

    @ViewBuilder
    private func runActions(_ run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        Menu {
            Button(run.pinned ? "Unpin Run" : "Pin Run") {
                model.setOrchestrationPinned(run, pinned: !run.pinned)
            }
            if presentation.canRecover, run.runKind != "solo" {
                if run.checkpoint?.state["fallback_action"]?.string == "run_with_locus" {
                    Button("Run with Locus") { model.runOrchestrationWithLocus(run) }
                } else {
                    Button("Resume") { model.resumeOrchestration(run) }
                }
            }
            if run.runKind == "solo",
               ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
                Button("Retry Run") { model.retryRun(run) }
            }
            if run.taskID != nil && !run.legacy {
                Button("Replay Same Baseline") { model.replayOrchestration(run) }
            }
            if !run.legacy {
                Button("Duplicate from Current Workspace") { model.duplicateOrchestration(run) }
            }
            if presentation.canPause {
                Button("Pause at Safe Boundary") { model.pauseOrchestration(run.id) }
            }
            if presentation.canStop {
                Button("Stop Run", role: .destructive) { model.cancelOrchestration(run.id) }
            }
            Menu("Export") {
                Button("Redacted .locusrun") {
                    Task { await model.exportOrchestration(run.id, includeContent: false) }
                }
                Button("Include Visible Content…") {
                    Task { await model.exportOrchestration(run.id, includeContent: true) }
                }
                if model.settings.otlpExportEnabled,
                   !model.settings.otlpEndpoint.trimmingCharacters(
                    in: .whitespacesAndNewlines
                   ).isEmpty
                {
                    Divider()
                    Button(
                        run.exportState == "failed"
                            ? "Retry Metadata Trace" : "Send Metadata Trace"
                    ) {
                        Task { await model.exportRunToOTLP(run.id) }
                    }
                    Button("Send Content Trace…") {
                        telemetryContentRunID = run.id
                    }
                }
            }
            Divider()
            Button("Discard Run", role: .destructive) { model.discardOrchestration(run.id) }
                .disabled(
                    presentation.isActivelyOwned
                        || (!presentation.state.isTerminal && !presentation.canRecover)
                )
            if run.taskID != nil && ["discarded", "cancelled", "completed", "failed"].contains(run.state) {
                Button("Clean Up Managed Checkout", role: .destructive) {
                    model.cleanupOrchestrationCheckout(run)
                }
                .disabled(model.isBusy)
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Run actions")
            .accessibilityIdentifier("runs.actions")
    }

    private func overview(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCard("REQUEST", symbol: "text.bubble") {
                    Text(run.request.isEmpty ? "No request was recorded." : run.request)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(8)
                }

                overviewCard("PROGRESS", symbol: "chart.bar.fill") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(runPhases(run).enumerated()), id: \.offset) { index, phase in
                            HStack(spacing: 8) {
                                Image(systemName: phase.done
                                    ? "checkmark.circle.fill"
                                    : phase.active ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(phase.done
                                        ? LocusTheme.success
                                        : phase.active ? LocusTheme.signalDeep : LocusTheme.lineStrong)
                                    .frame(width: 13)
                                Text(phase.title)
                                    .font(.locus(size: 9, weight: phase.active ? .bold : .regular))
                                Spacer()
                                if phase.active {
                                    Text("Current")
                                        .font(.locus(size: 7, weight: .semibold))
                                        .foregroundStyle(LocusTheme.signalDeep)
                                }
                            }
                            if index < runPhases(run).count - 1 {
                                Rectangle().fill(phase.done ? LocusTheme.success.opacity(0.4) : LocusTheme.line)
                                    .frame(width: 1, height: 7)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }

                teamAgentsAndJobs(run)

                overviewCard("RESULTS", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Jobs", "\(run.completedJobCount ?? 0) of \(run.jobCount ?? 0) completed")
                        metricRow("Duration", runDuration(run))
                        if let calls = run.usage?["model_calls"]?.integer {
                            metricRow("Model calls", calls.formatted())
                        }
                        if run.id == model.orchestrationRunID, !gitWorkspace.gitChanges.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Changed files")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.textSecondary)
                                ForEach(gitWorkspace.gitChanges.prefix(8)) { change in
                                    Text("\(change.status.marker)  \(change.path)")
                                        .font(.locus(size: 7, design: .monospaced))
                                        .lineLimit(1)
                                }
                                if gitWorkspace.gitChanges.count > 8 {
                                    Text("+ \(gitWorkspace.gitChanges.count - 8) more")
                                        .font(.locus(size: 7))
                                        .foregroundStyle(LocusTheme.textSecondary)
                                }
                            }
                        }
                        let presentation = model.teamRunPresentation(for: run.id, durable: run)
                        if let reason = run.recoveryReason,
                           !reason.isEmpty,
                           presentation.canRecover || presentation.state.isTerminal
                        {
                            Label(reason, systemImage: presentation.canRecover
                                ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                                .font(.locus(size: 8))
                                .foregroundStyle(presentation.canRecover
                                    ? LocusTheme.warning : LocusTheme.coral)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Run ID · \(run.id)")
                        Text("Saved events · \(run.lastSequence)")
                        if let checkpoint = run.checkpoint {
                            Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " "))")
                        }
                    }
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .padding(.top, 6)
                }
                .font(.locus(size: 8, weight: .semibold))
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.overview")
    }

    private func teamAgentsAndJobs(_ run: OrchestrationRun) -> some View {
        let attempts = agentTreeAttempts(run)
        let attemptedJobIDs = Set(attempts.map(\.jobID))
        let waitingJobs = (run.plan?.jobs ?? []).filter { !attemptedJobIDs.contains($0.id) }
        return overviewCard("AGENTS & JOBS", symbol: "person.2.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = run.plan?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.locus(size: 9, weight: .medium))
                }
                if attempts.isEmpty && waitingJobs.isEmpty {
                    Text("No jobs were assigned for this run.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.textSecondary)
                } else {
                    ForEach(attempts) { attempt in
                        agentTreeRow(attempt, run: run)
                    }
                    ForEach(waitingJobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "circle")
                                    .foregroundStyle(LocusTheme.lineStrong)
                                Text(job.agentID.isEmpty ? friendlyJobKind(job.kind) : job.agentID)
                                    .font(.locus(size: 8, weight: .bold))
                                Text("· waiting")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.textSecondary)
                            }
                            Text(job.goal)
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(3)
                            if !job.dependencies.isEmpty {
                                Text("Runs after: \(job.dependencies.joined(separator: ", "))")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.textSecondary)
                            }
                        }
                        .padding(.leading, 3)
                    }
                }
            }
            .accessibilityIdentifier("runs.agentTree")
        }
    }

    private func soloSwarmOverview(_ run: OrchestrationRun) -> some View {
        let work = runWork(run)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                runSummaryStrip(run, work: work)
                requestCard(run)
                whatHappenedCard(run, work: work)
                workersCard(run, work: work)
                if swarmHasUsageBreakdown(run) {
                    // A breakdown of numbers the strip already reports, so it
                    // opens on demand rather than competing with them.
                    DisclosureGroup("Token breakdown") {
                        VStack(alignment: .leading, spacing: 6) {
                            metricRow(
                                "Primary agent",
                                "\(swarmRootTokens(run).formatted()) tokens"
                            )
                            metricRow(
                                "Solo workers",
                                "\(swarmWorkerTokens(run).formatted()) tokens"
                            )
                            if let calls = swarmModelCalls(run) {
                                metricRow("Model calls", calls.formatted())
                            }
                            if let calls = run.usage?["worker_model_calls"]?.integer {
                                metricRow("Worker model calls", calls.formatted())
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.locus(size: 8, weight: .semibold))
                }
                technicalDetails(run)
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.soloSwarm.overview")
    }

    private func soloOverview(_ run: OrchestrationRun) -> some View {
        let work = runWork(run)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                runSummaryStrip(run, work: work)
                requestCard(run)
                whatHappenedCard(run, work: work)
                technicalDetails(run)
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.solo.overview")
    }

    /// The four numbers that answer "what happened here?" before any card does.
    ///
    /// Sized through `Font.locus`, which maps everything below 11 point onto one
    /// semantic style: the previous rows asked for 7, 8 and 9 point and all three
    /// rendered identically, so a duration and a token count carried exactly the
    /// same weight. Crossing the 11-point boundary buys a real step in the ramp
    /// without opting out of Dynamic Type.
    private func runSummaryStrip(_ run: OrchestrationRun, work: RunWork) -> some View {
        let files = work.files.count
        let tokens = swarmTotalTokens(run)
        let tokensHelp = if let calls = swarmModelCalls(run) {
            "Billed input + output across \(calls) model call\(calls == 1 ? "" : "s"). Each call re-sends the conversation and tool context."
        } else {
            "Billed input + output across every model call. Each call re-sends the conversation and tool context."
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                summaryStat(runDuration(run), "Duration")
                summaryStat(runStepCount(run, work: work).formatted(), "Steps")
                summaryStat(files.formatted(), files == 1 ? "File" : "Files")
                summaryStat(
                    tokens?.formatted(.number.notation(.compactName)) ?? "—", "Tokens",
                    help: tokensHelp
                )
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    summaryStat(runDuration(run), "Duration")
                    summaryStat(runStepCount(run, work: work).formatted(), "Steps")
                }
                GridRow {
                    summaryStat(files.formatted(), files == 1 ? "File" : "Files")
                    summaryStat(
                        tokens?.formatted(.number.notation(.compactName)) ?? "—", "Tokens",
                        help: tokensHelp
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.summaryStrip")
    }

    private func summaryStat(_ value: String, _ label: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.locus(size: 15, weight: .semibold))
                .foregroundStyle(LocusTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.locus(size: 7, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
        // One element, one phrase: read as "Steps, 4" rather than as two
        // unrelated fragments. A collapsed element does not carry a separate
        // accessibility value, so the number belongs in the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityIdentifier("runs.summaryStat.\(label.lowercased())")
    }

    /// The request as the person typed it. `run.request` is the composer's
    /// decorated prompt, which opens with a mode header and several paragraphs
    /// of standing instruction — clamping that showed the boilerplate and cut
    /// off the only part anyone came to read. The transcript already strips it.
    private func requestCard(_ run: OrchestrationRun) -> some View {
        let text = AppModel.displayUserText(run.request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = text.count > 220 || text.contains("\n")
        return overviewCard("REQUEST", symbol: "text.bubble") {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.isEmpty ? "No request was recorded." : text)
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(requestExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if clamped, !text.isEmpty {
                    Button(requestExpanded ? "Show less" : "Show more") {
                        withAnimation(LocusMotion.content) { requestExpanded.toggle() }
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.request.expand")
                }
            }
        }
    }

    /// Files written and commands run, rebuilt from the run's own events. The
    /// panel used to answer this from live git status, so it went blank the
    /// moment you opened a run that had already finished.
    @ViewBuilder
    private func whatHappenedCard(_ run: OrchestrationRun, work: RunWork) -> some View {
        overviewCard("WHAT HAPPENED", symbol: "hammer") {
            if work.isEmpty {
                Text(run.state == "running"
                    ? "Nothing recorded yet."
                    : "This run wrote no files and ran no commands.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runs.work.empty")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !work.files.isEmpty {
                        workSubhead("Files", work.files.count)
                        SummaryList(
                            work.files,
                            identifierPrefix: "runs.work.file",
                            noun: "file"
                        ) { _, change in
                            SummaryRow(
                                icon: .forPath(change.path),
                                label: change.path,
                                meta: change.effect,
                                identifier: "runs.work.file.\(change.path)",
                                help: change.path,
                                action: fileOpener(run, path: change.path)
                            )
                        }
                    }
                    if !work.commands.isEmpty {
                        workSubhead("Commands", work.commands.count)
                        SummaryList(
                            work.commands,
                            identifierPrefix: "runs.work.command",
                            noun: "command"
                        ) { _, command in
                            SummaryRow(
                                icon: .process,
                                label: command.summary,
                                meta: command.ok ? nil : "failed",
                                metaColor: LocusTheme.dangerForeground,
                                identifier: "runs.work.command.\(command.id)",
                                help: command.summary,
                                // A command reads from the left; keeping its
                                // tail made two different `python3 -m unittest`
                                // invocations render as the same row.
                                truncation: .tail
                            )
                        }
                    }
                }
            }
        }
    }

    private func workSubhead(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.locus(size: 7, weight: .bold))
                .tracking(0.5)
            Text(count.formatted())
                .font(.locus(size: 7, design: .monospaced))
        }
        .foregroundStyle(LocusTheme.textSecondary)
    }

    /// Only offered where activating it is safe and meaningful: the run has to
    /// belong to the workspace that is open, or the path resolves somewhere else
    /// entirely.
    private func fileOpener(_ run: OrchestrationRun, path: String) -> (() -> Void)? {
        guard let root = run.workspaceRoot, root == model.workspacePath else { return nil }
        return { model.openSessionFile(path) }
    }

    /// Workers earn a card when there were any. When there were none, the fact
    /// belongs in one line — and it has to say *which* kind of none it was: the
    /// agent seeing no reason to split the work reads nothing like delegation
    /// having been unavailable, and the two used to be indistinguishable.
    @ViewBuilder
    private func workersCard(_ run: OrchestrationRun, work: RunWork) -> some View {
        if usesLiveSwarmWorkers(run) {
            overviewCard("WORKERS", symbol: "person.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.agentActivities.filter { $0.depth == 1 }) { activity in
                        liveSwarmWorkerRow(activity)
                    }
                }
            }
        } else if !agentTreeAttempts(run).isEmpty {
            overviewCard(
                "WORKERS · \(swarmCompletedCount(run)) OF \(swarmWorkerCount(run))",
                symbol: "person.fill"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agentTreeAttempts(run)) { attempt in
                        swarmAttemptRow(attempt)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: work.delegationUnavailable
                    ? "exclamationmark.triangle" : "person.slash")
                    .font(.locus(size: 8))
                    .foregroundStyle(work.delegationUnavailable
                        ? LocusTheme.warningForeground : LocusTheme.textTertiary)
                Text(workersEmptyText(run, work: work))
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("runs.soloSwarm.noWorkers")
        }
    }

    private func workersEmptyText(_ run: OrchestrationRun, work: RunWork) -> String {
        if work.delegationUnavailable {
            return "Delegation was unavailable for this run, so the agent worked alone."
        }
        if run.state == "running" { return "No workers delegated yet." }
        return "This run did not delegate any workers — the primary agent can finish "
            + "a Solo request itself when parallel investigation would not help."
    }

    /// Tool steps: what the run did, rather than how many times a provider was
    /// asked. `usage.tool_steps` is authoritative when the agent reported it;
    /// runs recorded before that field existed are counted from their own
    /// persisted tool results, so history reads correctly too.
    private func runStepCount(_ run: OrchestrationRun, work: RunWork) -> Int {
        if let steps = run.usage?["tool_steps"]?.integer, steps > 0 { return steps }
        return work.toolSteps
    }

    private func runWork(_ run: OrchestrationRun) -> RunWork {
        RunWork(events: runs.orchestrationEvents(for: run.id))
    }

    private func technicalDetails(_ run: OrchestrationRun) -> some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Run ID · \(run.id)")
                Text("Saved events · \(run.lastSequence)")
                Text("Started · \(runTimestamp(run.createdAt))")
                if let ended = run.completedAt {
                    Text("Ended · \(runTimestamp(ended))")
                }
                if let model = runModelLabel(run) {
                    Text("Model · \(model)")
                }
                if let root = run.workspaceRoot, !root.isEmpty {
                    Text("Workspace · \(root)")
                }
                if let environment = run.executionEnvironment, !environment.isEmpty {
                    Text("Environment · \(environment)")
                }
                if let trace = run.traceID, !trace.isEmpty {
                    Text("Trace · \(trace)")
                }
                if let checkpoint = run.checkpoint {
                    Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " "))")
                }
            }
            .font(.locus(size: 7, design: .monospaced))
            .foregroundStyle(LocusTheme.textTertiary)
            .textSelection(.enabled)
            .padding(.top, 6)
        }
        .font(.locus(size: 8, weight: .semibold))
        .accessibilityIdentifier("runs.technicalDetails")
    }

    private func runTimestamp(_ value: Double) -> String {
        Date(timeIntervalSince1970: value)
            .formatted(date: .abbreviated, time: .standard)
    }

    /// Provider and model are reported on the turn's terminal event, which the
    /// run row itself does not carry.
    private func runModelLabel(_ run: OrchestrationRun) -> String? {
        guard let terminal = runs.orchestrationEvents(for: run.id).last(where: {
            $0.type == "turn_done" || $0.type == "orchestration_completed"
        }) else { return nil }
        let name = terminal.text("model") ?? ""
        let provider = terminal.text("provider") ?? ""
        let label = [provider, name].filter { !$0.isEmpty }.joined(separator: " · ")
        return label.isEmpty ? nil : label
    }

    private func usesLiveSwarmWorkers(_ run: OrchestrationRun) -> Bool {
        run.id == model.orchestrationRunID
            && model.isBusy
            && model.agentActivities.contains { $0.depth == 1 }
    }

    private func liveSwarmWorkerRow(_ activity: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: activity.state == .completed
                    ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(activity.state == .completed
                        ? LocusTheme.success : LocusTheme.signalDeep)
                Text(activity.agentName)
                    .font(.locus(size: 9, weight: .semibold))
                Spacer()
                Text(activity.state.title)
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            Text(activity.goal)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(3)
            Text([activity.provider, activity.model,
                  activity.executionEngine.replacingOccurrences(of: "_", with: " ")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.textSecondary)
                .lineLimit(1)
            if !activity.output.isEmpty, activity.output != "Branch started" {
                Text(activity.output)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(LocusTheme.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func swarmAttemptRow(_ attempt: AgentJobAttempt) -> some View {
        let accessibleDetails = [
            attempt.output,
            attempt.evidence.isEmpty ? nil : "Evidence: \(attempt.evidence.joined(separator: ", "))",
            attempt.uncertainties.isEmpty ? nil : "Uncertainties: \(attempt.uncertainties.joined(separator: ", "))",
            "\(attempt.modelCalls) calls, \(attempt.promptTokens + attempt.completionTokens) tokens"
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: attempt.state == "completed"
                    ? "checkmark.circle.fill"
                    : attempt.state == "failed" ? "exclamationmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(attempt.state == "completed"
                        ? LocusTheme.success
                        : attempt.state == "failed" ? LocusTheme.coral : LocusTheme.signalDeep)
                Text(attempt.agentName ?? attempt.agentID ?? "Worker")
                    .font(.locus(size: 9, weight: .semibold))
                Spacer()
                Text(attempt.state.replacingOccurrences(of: "_", with: " "))
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            Text(attempt.goal)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(3)
            Text([attempt.provider, attempt.model,
                  attempt.resolvedExecutionEngine.replacingOccurrences(of: "_", with: " ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.textSecondary)
                .lineLimit(1)
            if let output = attempt.output, !output.isEmpty {
                Text(output)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if !attempt.evidence.isEmpty {
                Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(4)
            }
            if !attempt.uncertainties.isEmpty {
                Text("Uncertainties · \(attempt.uncertainties.joined(separator: ", "))")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.warning)
                    .lineLimit(4)
            }
            Text("\(attempt.modelCalls) calls · \((attempt.promptTokens + attempt.completionTokens).formatted()) tokens")
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.textSecondary)
        }
        .padding(8)
        .background(LocusTheme.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityValue(accessibleDetails)
        .accessibilityIdentifier("runs.soloSwarm.worker.\(attempt.resolvedNodeID)")
    }

    private func swarmWorkerCount(_ run: OrchestrationRun) -> Int {
        if usesLiveSwarmWorkers(run) {
            return Set(model.agentActivities.filter { $0.depth == 1 }.map { $0.nodeID ?? $0.id }).count
        }
        return agentTreeAttempts(run).count
    }

    private func swarmCompletedCount(_ run: OrchestrationRun) -> Int {
        if usesLiveSwarmWorkers(run) {
            return model.agentActivities.filter { $0.depth == 1 && $0.state == .completed }.count
        }
        return agentTreeAttempts(run).filter { $0.state == "completed" }.count
    }

    private func swarmModelCalls(_ run: OrchestrationRun) -> Int? {
        if usesLiveSwarmWorkers(run), model.teamModelCalls > 0 { return model.teamModelCalls }
        return run.usage?["model_calls"]?.integer
    }

    private func swarmTotalTokens(_ run: OrchestrationRun) -> Int? {
        if usesLiveSwarmWorkers(run), model.teamMeteredTokens > 0 { return model.teamMeteredTokens }
        if let total = run.usage?["metered_tokens"]?.integer { return total }
        guard let prompt = run.usage?["prompt_tokens"]?.integer,
              let completion = run.usage?["completion_tokens"]?.integer else { return nil }
        return prompt + completion
    }

    private func swarmRootTokens(_ run: OrchestrationRun) -> Int {
        (run.usage?["root_prompt_tokens"]?.integer ?? 0)
            + (run.usage?["root_completion_tokens"]?.integer ?? 0)
    }

    private func swarmWorkerTokens(_ run: OrchestrationRun) -> Int {
        (run.usage?["worker_prompt_tokens"]?.integer ?? 0)
            + (run.usage?["worker_completion_tokens"]?.integer ?? 0)
    }

    private func swarmHasUsageBreakdown(_ run: OrchestrationRun) -> Bool {
        run.usage?["root_prompt_tokens"] != nil || run.usage?["worker_prompt_tokens"] != nil
    }

    private func activity(_ run: OrchestrationRun) -> some View {
        let groups = activityGroups(run)
        return VStack(spacing: 0) {
            HStack {
                TextField("Filter run activity", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                // Renamed from "Technical log": with the list above now
                // showing the run's actual work, this is the raw firehose you
                // reach for to debug, not the only way to see anything at all.
                Toggle("Raw events", isOn: $showTechnicalLog)
                    .toggleStyle(.checkbox)
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.technicalLog")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
            if showTechnicalLog {
                timeline(run, showsFilter: false)
            } else {
                ScrollView {
                    if groups.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.locus(size: 20))
                                .foregroundStyle(LocusTheme.muted)
                            Text(filter.isEmpty ? "No activity recorded" : "No matching activity")
                                .font(.locus(size: 9, weight: .semibold))
                            Text(filter.isEmpty
                                ? "Events will appear here as this run progresses."
                                : "Try a different search term, or switch on Raw events.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                Text(group.title.uppercased())
                                    .font(.locus(size: 7, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(LocusTheme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                ForEach(group.events) { event in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: friendlyEventSymbol(event))
                                            .foregroundStyle(eventColor(event))
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friendlyEventTitle(event))
                                                .font(.locus(size: 9, weight: .semibold))
                                            Text(friendlyEventDetail(event))
                                                .font(.locus(size: 8))
                                                .foregroundStyle(LocusTheme.textSecondary)
                                                .lineLimit(4)
                                        }
                                        Spacer(minLength: 6)
                                        // Offsets, not clock times: what a
                                        // reader wants from a run's timeline is
                                        // how long it took to get here.
                                        if let offset = eventOffset(event, in: run) {
                                            Text(offset)
                                                .font(.locus(size: 7, design: .monospaced))
                                                .foregroundStyle(LocusTheme.textTertiary)
                                                .accessibilityLabel("at \(offset)")
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    // Spelled out rather than combined: a
                                    // combined row reports an empty label here,
                                    // which reads as an undescribed element.
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(activityRowLabel(event, in: run))
                                    .accessibilityIdentifier("runs.activity.event.\(event.id)")
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.activity")
    }

    private func overviewCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.textSecondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same chrome as the Overview tab's summary cards, so the two
        // surfaces read as siblings instead of as two nearly-identical recipes.
        .summaryCardChrome()
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(LocusTheme.textSecondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.locus(size: 8))
    }

    private func agentTreeAttempts(_ run: OrchestrationRun) -> [AgentJobAttempt] {
        var latest: [String: AgentJobAttempt] = [:]
        for attempt in run.attempts ?? [] {
            let node = attempt.resolvedNodeID
            if latest[node] == nil || attempt.attempt > (latest[node]?.attempt ?? 0) {
                latest[node] = attempt
            }
        }
        return latest.values.sorted {
            if $0.resolvedDepth != $1.resolvedDepth {
                return $0.resolvedDepth < $1.resolvedDepth
            }
            let left = $0.startedAt ?? 0
            let right = $1.startedAt ?? 0
            return left == right ? $0.resolvedNodeID < $1.resolvedNodeID : left < right
        }
    }

    private func agentTreeRow(_ attempt: AgentJobAttempt, run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        let isCoding = model.isCodingAttempt(attempt, in: run)
        let branchError = attempt.result?["error"]?.string
        return HStack(alignment: .top, spacing: 7) {
            HStack(spacing: 3) {
                if attempt.resolvedDepth > 0 {
                    Rectangle()
                        .fill(LocusTheme.lineStrong)
                        .frame(width: 1, height: 20)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.muted)
                }
                Image(systemName: attempt.state == "completed"
                    ? "checkmark.circle.fill"
                    : attempt.state == "stopped" ? "stop.circle.fill"
                    : attempt.state == "failed" ? "exclamationmark.circle.fill"
                    : "circle.dotted")
                    .foregroundStyle(attempt.state == "completed"
                        ? LocusTheme.success
                        : ["failed", "stopped"].contains(attempt.state)
                            ? LocusTheme.coral : LocusTheme.signalDeep)
            }
            .frame(width: CGFloat(attempt.resolvedDepth * 14 + 17), alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                        .font(.locus(size: 8, weight: .bold))
                    Text("· \(attempt.state.replacingOccurrences(of: "_", with: " "))")
                        .font(.locus(size: 7, design: .monospaced))
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                Text("\(attempt.provider ?? "Unknown provider") · \(attempt.model ?? "Unknown model") · \(attempt.resolvedExecutionEngine.replacingOccurrences(of: "_", with: " "))")
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(1)
                Text(attempt.goal)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
                if let branchError, !branchError.isEmpty {
                    Text(branchError)
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.coral)
                        .lineLimit(3)
                }
                if !attempt.evidence.isEmpty {
                    Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(3)
                }
                Text("\(attempt.modelCalls) calls · \(attempt.promptTokens + attempt.completionTokens) tokens · \(attempt.elapsedMilliseconds) ms")
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            Spacer(minLength: 0)
            if !run.isSoloSwarm,
               presentation.isActivelyOwned, attempt.state == "running", !isCoding {
                Button("Stop") { model.stopOrchestrationBranch(attempt, in: run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 7, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
                    .accessibilityIdentifier("runs.agentTree.stop.\(attempt.resolvedNodeID)")
            } else if !run.isSoloSwarm,
                      presentation.canRecover,
                      ["failed", "stopped", "paused"].contains(attempt.state),
                      !isCoding {
                Button("Retry") { model.retryOrchestrationBranch(attempt, in: run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 7, weight: .semibold))
                    .accessibilityIdentifier("runs.agentTree.retry.\(attempt.resolvedNodeID)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.agentTree.node.\(attempt.resolvedNodeID)")
    }

    private func timeline(_ run: OrchestrationRun, showsFilter: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsFilter {
                TextField("Filter agent, event, state, or attempt", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEvents(run)) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(event.sequence)")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.textSecondary)
                                .frame(width: 30, alignment: .trailing)
                            Circle().fill(color(for: event.type)).frame(width: 6, height: 6).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.type.replacingOccurrences(of: "_", with: " "))
                                    .font(.locus(size: 8, weight: .bold))
                                Text(event.title)
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .lineLimit(4)
                                if let detail = event.detail, detail != event.title {
                                    Text(detail)
                                        .font(.locus(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.textSecondary)
                                        .lineLimit(12)
                                        .textSelection(.enabled)
                                }
                                if let job = event.jobID {
                                    Text("job \(job)\(event.attemptID.map { " · \($0)" } ?? "")")
                                        .font(.locus(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func dependencyView(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.attempts ?? []) { attempt in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: attempt.state == "completed" ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(attempt.state == "completed" ? LocusTheme.success : LocusTheme.signalDeep)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                                    .font(.locus(size: 9, weight: .bold))
                                Text("attempt \(attempt.attempt)")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.textSecondary)
                                Spacer()
                                if model.teamRunPresentation(
                                    for: run.id, durable: run
                                ).canRecover,
                                   attempt.state != "running"
                                    && !model.isCodingAttempt(attempt, in: run) {
                                    Menu {
                                        Button("Retry with Same Agent") {
                                            model.retryOrchestrationJob(attempt, in: run)
                                        }
                                        let candidates = model.reassignmentCandidates(
                                            for: attempt, in: run
                                        )
                                        if !candidates.isEmpty {
                                            Menu("Reassign") {
                                                ForEach(candidates) { profile in
                                                    Button(profile.name) {
                                                        model.reassignOrchestrationJob(
                                                            attempt, in: run, to: profile
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                }
                            }
                            Text(attempt.goal).font(.locus(size: 8)).lineLimit(4)
                            Text("\(attempt.role ?? "specialist") · \(attempt.state)")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.textSecondary)
                            if let provider = attempt.provider, !provider.isEmpty {
                                Text("\(provider) · \(attempt.model ?? "")")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.textSecondary)
                            }
                            if let output = attempt.output, !output.isEmpty {
                                Text(output)
                                    .font(.locus(size: 8))
                                    .lineLimit(12)
                                    .textSelection(.enabled)
                            }
                            if let reasoning = attempt.reasoningText,
                               !reasoning.isEmpty,
                               model.thinkingVisibility != .hidden
                            {
                                DisclosureGroup("Reasoning") {
                                    Text(reasoning)
                                        .font(.locus(size: 8))
                                        .foregroundStyle(LocusTheme.inkSoft)
                                        .textSelection(.enabled)
                                }
                                .font(.locus(size: 8, weight: .semibold))
                            }
                            if !attempt.evidence.isEmpty {
                                Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(4)
                            }
                            Text("\(attempt.elapsedMilliseconds) ms · \(attempt.promptTokens + attempt.completionTokens) tokens")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    .padding(9)
                    .background(LocusTheme.white.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(12)
        }
    }

    private func dispatchEditor(_ plan: DispatchPlan) -> some View {
        let validationErrors = model.dispatchPlanErrors(draftPlan ?? plan)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Review dispatch plan", systemImage: "checkmark.shield")
                    .font(.locus(size: 11, weight: .bold))
                Text("Edit goals, assignments, and dependencies. Coding jobs must form an explicit order; Locus runs them one at a time in the shared checkout.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Plan summary", text: planBinding(\.summary))
                    if draftPlan?.budget != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("RUN BUDGET")
                                .font(.locus(size: 7, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(LocusTheme.muted)
                            Stepper(
                                "Jobs · \(draftPlan?.budget?.maxJobs ?? 0)",
                                value: budgetBinding(\.maxJobs), in: 1...16
                            )
                            Stepper(
                                "Rounds · \(draftPlan?.budget?.maxRounds ?? 0)",
                                value: budgetBinding(\.maxRounds), in: 1...8
                            )
                            Picker("Call budget", selection: callBudgetModeBinding) {
                                ForEach(OrchestrationBudget.CallBudgetMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            if draftPlan?.budget?.callBudgetMode == .fixed {
                                Stepper(
                                    "Model calls · \(draftPlan?.budget?.maxModelCalls ?? 0)",
                                    value: budgetBinding(\.maxModelCalls), in: 1...100
                                )
                            }
                            Stepper(
                                "Concurrent calls · \(draftPlan?.budget?.maxConcurrentCalls ?? 0)",
                                value: budgetBinding(\.maxConcurrentCalls), in: 1...8
                            )
                            Stepper(
                                "Hosted tokens · \(draftPlan?.budget?.maxMeteredTokens ?? 0)",
                                value: budgetBinding(\.maxMeteredTokens),
                                in: 1_000...2_000_000,
                                step: 50_000
                            )
                            TextField(
                                "Maximum estimated cost (0 disables)",
                                value: maximumCostBinding,
                                format: .number.precision(.fractionLength(0...4))
                            )
                        }
                        .font(.locus(size: 8))
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(Array(plan.jobs.enumerated()), id: \.element.id) { index, job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.kind == "writer" ? "Coding" : job.kind.capitalized)
                                    .font(.locus(size: 8, weight: .bold))
                                Spacer()
                                Button(role: .destructive) {
                                    draftPlan?.jobs.remove(at: index)
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.locus())
                            }
                            TextField("Goal", text: jobBinding(index, \.goal), axis: .vertical)
                            Picker("Agent", selection: jobBinding(index, \.agentID)) {
                                ForEach(eligibleProfiles(for: job)) { profile in
                                    Text(profile.name).tag(profile.id.uuidString)
                                }
                            }
                            TextField("Dependencies", text: dependencyBinding(index), prompt: Text("job ids, comma separated"))
                        }
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    HStack {
                        Button {
                            addJob(kind: "specialist")
                        } label: { Label("Add Specialist Job", systemImage: "plus") }
                            .buttonStyle(.locus())
                        Button {
                            addJob(kind: "writer")
                        } label: { Label("Add Coding Job", systemImage: "hammer") }
                            .buttonStyle(.locus())
                            .accessibilityIdentifier("runs.addCodingJob")
                    }
                }
                .padding(12)
            }
            HStack {
                if let error = validationErrors.first {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.coral)
                        .lineLimit(2)
                }
                Button("Cancel") { model.decideDispatch("cancel") }
                Button("Re-dispatch") { model.decideDispatch("redispatch") }
                Spacer()
                Button("Run Plan") { model.decideDispatch("run", editedPlan: draftPlan) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!validationErrors.isEmpty)
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        }
    }

    private func eligibleProfiles(for job: DispatchJob) -> [AgentProfile] {
        guard let team = agentTeams.selectedAgentTeam else { return [] }
        return agentTeams.agentProfiles.filter { profile in
            guard team.memberIDs.contains(profile.id) else { return false }
            switch job.kind {
            case "writer":
                return profile.accessCeiling.canWrite
            case "reviewer":
                return !profile.accessCeiling.canWrite && profile.role == .reviewer
            default:
                return !profile.accessCeiling.canWrite
            }
        }
    }

    private func addJob(kind: String) {
        guard let plan = draftPlan else { return }
        let template = DispatchJob(
            id: "job-\(plan.jobs.count + 1)",
            agentID: "",
            goal: "",
            dependencies: [],
            kind: kind
        )
        guard let profile = eligibleProfiles(for: template).first else { return }
        var job = template
        job.agentID = profile.id.uuidString
        if kind == "writer",
           let priorWriter = plan.jobs.last(where: { $0.kind == "writer" })
        {
            job.dependencies = [priorWriter.id]
        }
        draftPlan?.jobs.append(job)
    }

    private func filteredEvents(_ run: OrchestrationRun) -> [OrchestrationEvent] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let durableEvents = runs.orchestrationEvents(for: run.id)
            .filter { !$0.isTransientStream }
        guard !query.isEmpty else { return durableEvents }
        return durableEvents.filter { event in
            [
                event.type, event.title, event.jobID, event.attemptID,
                event.text("agent_name"), event.text("agent_id"),
                event.text("state"), event.text("provider"), event.text("model"),
                event.text("reason"),
            ]
                .compactMap { $0 }.joined(separator: " ").lowercased().contains(query)
        }
    }

    private func planBinding(_ keyPath: WritableKeyPath<DispatchPlan, String>) -> Binding<String> {
        Binding(
            get: { draftPlan?[keyPath: keyPath] ?? "" },
            set: { draftPlan?[keyPath: keyPath] = $0 }
        )
    }

    private func jobBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<DispatchJob, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index][keyPath: keyPath]
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index][keyPath: keyPath] = value
                draftPlan = plan
            }
        )
    }

    private func dependencyBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index].dependencies.joined(separator: ", ")
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index].dependencies = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                draftPlan = plan
            }
        )
    }

    private func budgetBinding(
        _ keyPath: WritableKeyPath<OrchestrationBudget, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draftPlan?.budget?[keyPath: keyPath] ?? 1 },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget[keyPath: keyPath] = value
                budget.clamp()
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private var maximumCostBinding: Binding<Double> {
        Binding(
            get: { draftPlan?.maximumEstimatedCost ?? 0 },
            set: { value in
                guard var plan = draftPlan else { return }
                plan.maximumEstimatedCost = min(max(value, 0), 100_000)
                draftPlan = plan
            }
        )
    }

    private var callBudgetModeBinding: Binding<OrchestrationBudget.CallBudgetMode> {
        Binding(
            get: { draftPlan?.budget?.callBudgetMode ?? .fixed },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget.callBudgetMode = value
                if value == .automatic { budget.maxModelCalls = 100 }
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private struct RunPhase {
        let title: String
        let done: Bool
        let active: Bool
    }

    private struct ActivityGroup: Identifiable {
        let title: String
        let events: [OrchestrationEvent]
        var id: String { title }
    }

    private func activityGroups(_ run: OrchestrationRun) -> [ActivityGroup] {
        let visible = withoutRedundantWork(filteredEvents(run).filter(isUserFacingEvent))
        // Phase headings describe a team's shape. A solo turn that delegated
        // nothing has one phase, and filing its whole timeline under a "Solo
        // workers" heading described workers that never existed.
        if isSoloRun, agentTreeAttempts(runs.selectedOrchestrationRun).isEmpty {
            return visible.isEmpty ? [] : [ActivityGroup(title: "Timeline", events: visible)]
        }
        let order = ["Solo workers", "Planning", "Approval", "Specialists", "Coding jobs", "Review", "Complete"]
        let grouped = Dictionary(grouping: visible, by: activityPhase)
        return order.compactMap { title in
            guard let events = grouped[title], !events.isEmpty else { return nil }
            return ActivityGroup(title: title, events: events)
        }
    }

    private func agentTreeAttempts(_ run: OrchestrationRun?) -> [AgentJobAttempt] {
        run.map(agentTreeAttempts) ?? []
    }

    private func runPhases(_ run: OrchestrationRun) -> [RunPhase] {
        let state = model.teamRunPresentation(for: run.id, durable: run).state
        let current: Int = switch state {
        case .queued, .dispatching: 0
        case .waitingDispatchApproval: 1
        case .running, .waitingPermission, .waitingComputer:
            (run.attempts ?? []).contains { model.isCodingAttempt($0, in: run) } ? 3 : 2
        case .reviewing: 4
        case .completed: 5
        case .paused, .failed, .interrupted, .cancelled, .discarded:
            phaseIndex(for: run)
        }
        return ["Planning", "Plan approval", "Specialists", "Coding jobs", "Review", "Complete"]
            .enumerated().map { index, title in
                RunPhase(
                    title: title,
                    done: state == .completed || index < current,
                    active: state != .completed && index == current
                )
            }
    }

    private func phaseIndex(for run: OrchestrationRun) -> Int {
        let kind = run.checkpoint?.kind.lowercased() ?? ""
        if kind.contains("synthesis") { return 5 }
        if kind.contains("review") || kind.contains("revision") { return 4 }
        if kind.contains("writer") { return 3 }
        if kind.contains("dispatch") { return 2 }
        return run.plan == nil ? 0 : 2
    }

    private func runStateTitle(_ run: OrchestrationRun) -> String {
        let state = model.teamRunPresentation(for: run.id, durable: run).state.title
        let total = run.jobCount ?? 0
        guard total > 0 else { return state }
        let unit = run.isSoloSwarm ? "workers" : "jobs"
        return "\(state) · \(run.completedJobCount ?? 0) of \(total) \(unit)"
    }

    private func activityRowLabel(_ event: OrchestrationEvent, in run: OrchestrationRun) -> String {
        [
            friendlyEventTitle(event),
            friendlyEventDetail(event),
            eventOffset(event, in: run).map { "at \($0)" },
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func eventOffset(_ event: OrchestrationEvent, in run: OrchestrationRun) -> String? {
        guard let occurred = event.occurredAt else { return nil }
        let seconds = Int(occurred.timeIntervalSince1970 - run.createdAt)
        guard seconds >= 0 else { return nil }
        return String(format: "+%d:%02d", seconds / 60, seconds % 60)
    }

    private func runDuration(_ run: OrchestrationRun) -> String {
        let end = run.completedAt ?? run.updatedAt
        let seconds = max(Int(end - run.createdAt), 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func friendlyJobKind(_ kind: String) -> String {
        switch kind {
        case "writer": "Coding job"
        case "reviewer": "Review"
        default: "Specialist"
        }
    }

    /// A solo run is a team run's opposite: it emits no `agent_*` and no
    /// `orchestration_*` events, so the team-shaped allow-list below could only
    /// ever match its two lifecycle rows. The turn's tools *are* its activity,
    /// which is why the useful list used to live behind the raw-events switch.
    private func isUserFacingEvent(_ event: OrchestrationEvent) -> Bool {
        if isSoloRun, soloWorkEventTypes.contains(event.type) { return true }
        return event.type == "error"
            || ["run_started", "agent_spawned", "agent_branch_stopped",
                "swarm_telemetry", "turn_done", "note"].contains(event.type)
            || event.type == "permission_request"
            || event.type == "dispatch_plan_ready"
            || event.type == "dispatcher_plan_rejected"
            || event.type == "task_changes"
            || event.type.hasPrefix("agent_job_")
            || event.type.hasPrefix("orchestration_")
    }

    private var isSoloRun: Bool {
        runs.selectedOrchestrationRun?.runKind == "solo"
    }

    private var soloWorkEventTypes: Set<String> {
        ["tool_result", "tool_call_proposed", "workspace_changed"]
    }

    /// `tool_call_proposed` and `tool_result` are a pair; showing both doubles
    /// the list without adding a fact. The proposal survives only when no result
    /// followed it — a call that was denied, or one the turn was stopped during,
    /// which is exactly the case worth seeing. `workspace_changed` is dropped
    /// outright: the Overview's file list says the same thing with the paths.
    private func withoutRedundantWork(
        _ events: [OrchestrationEvent]
    ) -> [OrchestrationEvent] {
        guard isSoloRun else { return events }
        let resolved = Set(
            events.filter { $0.type == "tool_result" }.compactMap { $0.text("id") }
        )
        return events.filter { event in
            switch event.type {
            case "workspace_changed": false
            case "tool_call_proposed": !resolved.contains(event.text("id") ?? "")
            default: true
            }
        }
    }

    private func activityPhase(_ event: OrchestrationEvent) -> String {
        let isSoloSwarm = runs.selectedOrchestrationRun?.isSoloSwarm == true
        if isSoloSwarm,
           ["run_started", "agent_spawned", "agent_branch_stopped",
            "swarm_telemetry", "turn_done", "note"].contains(event.type)
                || event.type.hasPrefix("agent_job_") {
            return "Solo workers"
        }
        switch event.type {
        case "dispatch_plan_ready", "dispatch_plan", "dispatch_decision":
            return "Approval"
        case "dispatcher_plan_rejected":
            return "Planning"
        case "task_changes", "orchestration_completed":
            return "Complete"
        case "permission_request", "agent_job_continuing", "agent_job_incomplete":
            return "Coding jobs"
        case "agent_job_started", "agent_job_completed":
            if event.text("writer_position") != nil || event.text("writer_job_id") != nil {
                return "Coding jobs"
            }
            if event.text("role")?.lowercased() == "reviewer" {
                return "Review"
            }
            return "Specialists"
        case "orchestration_state":
            return event.text("state") == "reviewing" ? "Review" : "Planning"
        case "error", "orchestration_paused":
            return model.orchestrationState == .reviewing ? "Review" : "Coding jobs"
        default:
            return "Planning"
        }
    }

    private func friendlyEventTitle(_ event: OrchestrationEvent) -> String {
        let isSoloSwarm = runs.selectedOrchestrationRun?.isSoloSwarm == true
        return switch event.type {
        case "run_started": isSoloSwarm ? "Solo run started" : "Run started"
        case "agent_spawned": isSoloSwarm ? "Solo worker started" : "Agent started"
        case "agent_branch_stopped": isSoloSwarm ? "Solo worker stopped" : "Agent branch stopped"
        case "swarm_telemetry": "Worker batch completed"
        case "turn_done": isSoloSwarm ? "Solo run completed" : "Run completed"
        case "note": "Run note"
        case "orchestration_started": "Team run started"
        case "orchestration_state": event.text("state") == "reviewing" ? "Review started" : "Team progressed"
        case "dispatch_plan_ready": "Plan ready for your approval"
        case "dispatcher_plan_rejected": "Correcting dispatcher plan"
        case "agent_job_started": event.text("writer_position").map {
            "Coding job \($0) started"
        } ?? "Specialist started"
        case "agent_job_continuing": "Coding job is continuing"
        case "agent_job_incomplete": "Coding job needs more capacity"
        case "agent_job_completed": "Job completed"
        case "permission_request": "Waiting for permission"
        case "orchestration_paused": "Run paused safely"
        case "orchestration_completed": event.text("state") == "completed"
            ? "Team run completed" : "Team run stopped"
        case "task_changes": "Workspace changes are ready"
        case "error": "Run error"
        case "tool_result", "tool_call_proposed":
            event.text("summary")?.nilIfEmpty ?? event.text("tool") ?? "Tool call"
        default: event.title
        }
    }

    private func friendlyEventDetail(_ event: OrchestrationEvent) -> String {
        if event.type == "tool_result" {
            if event.values["denied"]?.boolean == true { return "Denied" }
            return event.text("result")?.nilIfEmpty ?? "Completed"
        }
        if event.type == "tool_call_proposed" {
            return event.text("detail")?.nilIfEmpty ?? "Never ran"
        }
        let agent = event.text("agent_name")
        let model = event.text("model")
        let route = [agent, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return event.text("message")?.nilIfEmpty
            ?? event.text("text")?.nilIfEmpty
            ?? event.text("goal")?.nilIfEmpty
            ?? event.text("reason")?.nilIfEmpty
            ?? event.detail?.nilIfEmpty
            ?? route.nilIfEmpty
            ?? event.title
    }

    private func friendlyEventSymbol(_ event: OrchestrationEvent) -> String {
        if event.type == "tool_call_proposed" { return "circle.dotted" }
        if event.type == "tool_result" {
            if event.values["denied"]?.boolean == true { return "hand.raised.circle.fill" }
            return event.values["ok"]?.boolean == false
                ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        }
        if event.type.contains("completed") { return "checkmark.circle.fill" }
        if event.type.contains("incomplete") || event.type.contains("paused") { return "pause.circle.fill" }
        if event.type.contains("error") || event.type.contains("rejected") { return "exclamationmark.circle.fill" }
        if event.type.contains("permission") { return "lock.circle.fill" }
        if event.type.contains("plan") { return "list.bullet.clipboard.fill" }
        return "circle.inset.filled"
    }

    /// `tool_result` carries its outcome in a flag, not in its type name, so
    /// the type-based palette painted a failed command the same green as a
    /// successful one.
    private func eventColor(_ event: OrchestrationEvent) -> Color {
        if event.type == "tool_result" {
            if event.values["denied"]?.boolean == true { return LocusTheme.warning }
            return event.values["ok"]?.boolean == false
                ? LocusTheme.coral : LocusTheme.success
        }
        if event.type == "tool_call_proposed" { return LocusTheme.muted }
        return color(for: event.type)
    }

    private func color(for type: String) -> Color {
        if type.contains("error") || type.contains("failed") { return LocusTheme.coral }
        if type.contains("completed") { return LocusTheme.success }
        if type.contains("waiting") || type.contains("permission") { return LocusTheme.warning }
        return LocusTheme.signalDeep
    }
}
