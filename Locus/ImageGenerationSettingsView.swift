import SwiftUI

/// The Image generation section of Settings › Models & Providers: which
/// account's Images API draws pictures, with what model and defaults, and
/// whether interactive answers render. Every control is an immediate
/// preference — the accounts page has no Save bar — and the status row shows
/// what the agent accepted after each push.
struct ImageGenerationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @ObservedObject var imageGeneration: ImageGenerationModel
    @Binding var draft: AppSettings
    let onAddAccount: () -> Void

    @State private var customModelSelected = false

    private static let otherModelTag = "__other__"

    var body: some View {
        Section("Image generation") {
            if capabilityDisabled {
                Text("The local agent has image generation switched off (image_generation_v1).")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.imageGeneration.capabilityNote")
            }

            Picker("Image account", selection: $draft.imageGenerationAccountID) {
                Text("None (off)").tag(String?.none)
                ForEach(eligibleAccounts) { account in
                    Text(account.displayName).tag(Optional(account.id.uuidString))
                }
            }
            .accessibilityIdentifier("settings.imageGeneration.account")

            if eligibleAccounts.isEmpty {
                HStack {
                    Text("Add an OpenAI API account to generate images.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.warning)
                        .accessibilityIdentifier("settings.imageGeneration.empty")
                    Spacer()
                    Button("Add Account…", action: onAddAccount)
                        .accessibilityIdentifier("settings.imageGeneration.addAccount")
                }
            }

            Picker("Model", selection: modelSelection) {
                ForEach(ProviderKind.curatedImageModels, id: \.self) { name in
                    Text(name).tag(name)
                }
                Text("Other…").tag(Self.otherModelTag)
            }
            .accessibilityIdentifier("settings.imageGeneration.model")

            if customModelSelected {
                TextField("Model name", text: $draft.imageGenerationModel)
                    .accessibilityIdentifier("settings.imageGeneration.customModel")
            }

            Picker("Default size", selection: $draft.imageGenerationSize) {
                ForEach(ImageGenerationSize.allCases) { size in
                    Text(size.title).tag(size.rawValue)
                }
            }
            .accessibilityIdentifier("settings.imageGeneration.size")

            Picker("Default quality", selection: $draft.imageGenerationQuality) {
                ForEach(ImageGenerationQuality.allCases) { quality in
                    Text(quality.title).tag(quality.rawValue)
                }
            }
            .accessibilityIdentifier("settings.imageGeneration.quality")

            Toggle("Render interactive answers", isOn: $draft.interactiveAnswersEnabled)
                .accessibilityIdentifier("settings.imageGeneration.interactiveAnswers")

            statusRow

            Text("With an account chosen, the agent gains generate_image and edit_image. Each call is approved by you first; the prompt — and for edits, the source image — is sent to that account's provider, and results are saved under Locus Images in the workspace. The API key is handed to the local agent in memory and never written to its config.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.imageGeneration.footer")
        }
        .id("settings.imageGeneration")
        .disabled(capabilityDisabled)
        .onAppear {
            customModelSelected = !ProviderKind.curatedImageModels
                .contains(draft.imageGenerationModel)
        }
    }

    private var capabilityDisabled: Bool {
        model.backendCapabilities["image_generation_v1"] == false
    }

    private var eligibleAccounts: [ProviderAccount] {
        // Read through the accounts model so the picker refreshes as accounts
        // are added or removed while this page is open.
        providerAccounts.providerAccounts.filter { account in
            account.kind.supportsImageGeneration
                && account.isCredentialReady(in: model.credentialStore)
                && !account.resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Curated names select directly; "Other…" reveals the free-text field
    /// and keeps whatever name it holds.
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if customModelSelected { return Self.otherModelTag }
                return ProviderKind.curatedImageModels.contains(draft.imageGenerationModel)
                    ? draft.imageGenerationModel
                    : Self.otherModelTag
            },
            set: { newValue in
                if newValue == Self.otherModelTag {
                    customModelSelected = true
                } else {
                    customModelSelected = false
                    draft.imageGenerationModel = newValue
                }
            }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if imageGeneration.isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.imageGeneration.status")
    }

    private var statusText: String {
        if let error = imageGeneration.lastError {
            return "Not applied: \(error)"
        }
        guard draft.imageGenerationAccountID != nil else {
            return "Off — the agent has no image tools."
        }
        guard let state = imageGeneration.state else {
            return "Waiting for the local agent."
        }
        guard state.configured else {
            return "Off — the agent has no image tools."
        }
        let host = state.host.isEmpty ? state.accountLabel : model.shortHost(state.host)
        return "Ready: \(state.model) via \(host)"
    }

    private var statusColor: Color {
        if imageGeneration.lastError != nil { return LocusTheme.coral }
        guard draft.imageGenerationAccountID != nil,
              imageGeneration.state?.configured == true
        else { return LocusTheme.muted }
        return LocusTheme.success
    }
}
