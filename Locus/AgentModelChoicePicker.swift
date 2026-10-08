import SwiftUI

/// Assignment is account scoped, including when two providers use the same
/// model name. The profile stores references only; credentials stay in Keychain.
struct AgentModelChoicePicker: View {
    @Environment(\.locusViewColors) private var colors
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @Environment(\.dismiss) private var dismiss
    @State private var route: AgentRoute = .localOllama
    @State private var modelName = ""
    @State private var refreshing = false
    let assigned: [AgentModelChoice]
    let onAssign: (AgentModelChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Assign a model")
                .font(.locus(size: 17, weight: .semibold))
            Text("The agent chooses a model for each task and can try another assigned model if the first cannot start.")
                .font(.locus(size: 11))
                .foregroundStyle(colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Provider", selection: routeBinding) {
                Text("Local Ollama").tag(AgentRoute.localOllama)
                ForEach(providerAccounts.providerAccounts) { account in
                    Text(account.displayName).tag(AgentRoute.providerAccount(account.id))
                }
            }
            .accessibilityIdentifier("agent.models.provider")
            if options.choices.isEmpty {
                TextField("Exact model ID", text: $modelName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("agent.models.manual")
            } else {
                Picker("Model", selection: $modelName) {
                    Text("Choose a model…").tag("")
                    ForEach(options.choices, id: \.self) { name in Text(name).tag(name) }
                }
                .accessibilityIdentifier("agent.models.picker")
            }
            if duplicate {
                Text("This model and account are already assigned.")
                    .font(.locus(size: 10))
                    .foregroundStyle(colors.textTertiary)
            }
            HStack {
                if refreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Assign model") {
                    guard let choice = choice.normalized else { return }
                    onAssign(choice)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || duplicate || options.availability(of: modelName) == .unavailable)
                .accessibilityIdentifier("agent.models.confirm")
            }
        }
        .padding(24)
        .frame(width: 470)
        .background(colors.surfaceCanvas)
        .task(id: route) {
            refreshing = true
            let requested = route
            switch requested {
            case .localOllama: await model.refreshMetadata()
            case .providerAccount(let id): await providerAccounts.refreshAccountCatalogs(force: true, accountID: id)
            }
            guard requested == route else { return }
            refreshing = false
        }
    }

    private var choice: AgentModelChoice { .init(route: route, model: modelName) }
    private var duplicate: Bool { assigned.contains { $0.id == choice.id } }
    private var options: AgentProfileModelOptions { options(for: route) }

    private var routeBinding: Binding<AgentRoute> {
        Binding(get: { route }, set: { next in
            route = next
            modelName = options(for: next).choices.first ?? ""
        })
    }

    private func options(for route: AgentRoute) -> AgentProfileModelOptions {
        switch route {
        case .localOllama:
            AgentProfileModelOptions(account: nil,
                reportedModels: providerAccounts.localModels.map(\.name),
                hasAuthoritativeCatalog: !refreshing && !providerAccounts.localModels.isEmpty)
        case .providerAccount(let id):
            AgentProfileModelOptions(account: providerAccounts.providerAccounts.first { $0.id == id },
                reportedModels: providerAccounts.accountModels[id] ?? [],
                hasAuthoritativeCatalog: !refreshing && providerAccounts.hasAuthoritativeModelCatalog(for: id))
        }
    }
}
