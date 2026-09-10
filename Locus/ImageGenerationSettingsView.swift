import SwiftUI

/// The Image generation section of Settings › Models & Providers: which
/// account draws pictures, with what model and defaults, and
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
    /// The custom model name while it is being typed. The draft — and with it
    /// the push to the agent — takes the value once it is committed, not on
    /// every keystroke.
    @State private var customModelText = ""
    @FocusState private var customModelFocused: Bool
    @State private var customSizeSelected = false
    @State private var customSizeText = ""
    @State private var customSizeError: String?
    @FocusState private var customSizeFocused: Bool

    private static let otherModelTag = "__other__"
    private static let customSizeTag = "__custom_size__"

    var body: some View {
        Section("Image generation") {
            if imageControlsDisabled {
                Text("The local agent has image generation switched off (image_generation_v1).")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.imageGeneration.capabilityNote")
            }

            Group {
                Picker("Image account", selection: $draft.imageGenerationAccountID) {
                    Text("None (off)").tag(String?.none)
                    ForEach(eligibleAccounts) { account in
                        Text(account.displayName).tag(Optional(account.id.uuidString))
                    }
                }
                .accessibilityIdentifier("settings.imageGeneration.account")

                if eligibleAccounts.isEmpty {
                    HStack {
                        Text("Add a ChatGPT or OpenAI API account to generate images.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.warning)
                            .accessibilityIdentifier("settings.imageGeneration.empty")
                        Spacer()
                        Button("Add Account…", action: onAddAccount)
                            .accessibilityIdentifier("settings.imageGeneration.addAccount")
                    }
                }

                if isChatGPTSelected {
                    LabeledContent("Model", value: "GPT Image 2")
                        .accessibilityIdentifier("settings.imageGeneration.chatGPTModel")
                    Text("Uses your ChatGPT plan through OpenAI’s managed runtime. Size and quality are chosen automatically; describe preferences in your request. Account availability and plan limits apply.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Model", selection: modelSelection) {
                        ForEach(ProviderKind.curatedImageModels, id: \.self) { name in
                            Text(ProviderKind.imageModelTitle(name)).tag(name)
                        }
                        Text("Other…").tag(Self.otherModelTag)
                    }
                    .accessibilityIdentifier("settings.imageGeneration.model")

                    if ImageGenerationOptions.hasExtendedQuality(draft.imageGenerationModel) {
                        Text("Sunburst is best for precise edits. Flare is designed for fast everyday image generation.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if customModelSelected {
                        TextField("Model name", text: $customModelText)
                            .focused($customModelFocused)
                            .onSubmit(commitCustomModel)
                            .onChange(of: customModelFocused) { _, focused in
                                if !focused { commitCustomModel() }
                            }
                            .onAppear { customModelText = draft.imageGenerationModel }
                            .onDisappear {
                                // Picking a curated name hides this field after the
                                // picker has already written the draft; only a
                                // field that leaves while still "Other…" commits.
                                if customModelSelected { commitCustomModel() }
                            }
                            .accessibilityIdentifier("settings.imageGeneration.customModel")
                    }

                    Picker("Default size", selection: sizeSelection) {
                        ForEach(ImageGenerationOptions.sizes(for: draft.imageGenerationModel)) { size in
                            Text(size.title).tag(size.rawValue)
                        }
                        if ImageGenerationOptions.hasCustomSizes(draft.imageGenerationModel) {
                            Text("Custom…").tag(Self.customSizeTag)
                        }
                    }
                    .accessibilityIdentifier("settings.imageGeneration.size")

                    if customSizeSelected && ImageGenerationOptions.hasCustomSizes(draft.imageGenerationModel) {
                        TextField("Custom dimensions", text: $customSizeText, prompt: Text("1536x864"))
                            .focused($customSizeFocused)
                            .onSubmit(commitCustomSize)
                            .onChange(of: customSizeFocused) { _, focused in
                                if !focused { commitCustomSize() }
                            }
                            .onDisappear {
                                if customSizeSelected && ImageGenerationOptions.hasCustomSizes(draft.imageGenerationModel) {
                                    commitCustomSize()
                                }
                            }
                            .accessibilityIdentifier("settings.imageGeneration.customSize")
                        if let customSizeError {
                            Text(customSizeError)
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.warning)
                                .accessibilityIdentifier("settings.imageGeneration.customSizeError")
                        }
                    }
                    if ImageGenerationOptions.hasCustomSizes(draft.imageGenerationModel) {
                        Text(ImageGenerationOptions.sizeHelp)
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Default quality", selection: $draft.imageGenerationQuality) {
                        ForEach(ImageGenerationOptions.qualities(for: draft.imageGenerationModel)) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.imageGeneration.quality")
                }
            }
            .disabled(imageControlsDisabled)

            if interactiveToggleDisabled {
                Text("The local agent has interactive answers switched off (interactive_answers_v1).")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.imageGeneration.interactiveCapabilityNote")
            }

            // Governed by its own capability: interactive answers render with
            // or without an image provider.
            Toggle("Render interactive answers", isOn: $draft.interactiveAnswersEnabled)
                .disabled(interactiveToggleDisabled)
                .accessibilityIdentifier("settings.imageGeneration.interactiveAnswers")

            statusRow
                .disabled(imageControlsDisabled)

            Text("With an account chosen, the agent gains generate_image and edit_image. Each call is approved by you first; the prompt — and for edits, the source image — is sent to that account's provider, and results are saved under Locus Images in the workspace. ChatGPT sign-in stays inside OpenAI’s managed runtime. API accounts use their own key and billing.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.imageGeneration.footer")
        }
        .id("settings.imageGeneration")
        .onAppear {
            customModelSelected = !ProviderKind.curatedImageModels
                .contains(draft.imageGenerationModel)
            customModelText = draft.imageGenerationModel
            resetCustomSizeEditor()
        }
    }

    private var imageControlsDisabled: Bool {
        Self.imageControlsDisabled(capabilities: model.backendCapabilities)
    }

    private var interactiveToggleDisabled: Bool {
        Self.interactiveToggleDisabled(capabilities: model.backendCapabilities)
    }

    /// The image controls follow `image_generation_v1`; an absent flag is an
    /// older agent that has the feature on.
    static func imageControlsDisabled(capabilities: [String: Bool]) -> Bool {
        capabilities["image_generation_v1"] == false
    }

    /// The interactive kill switch follows `interactive_answers_v1` alone.
    static func interactiveToggleDisabled(capabilities: [String: Bool]) -> Bool {
        capabilities["interactive_answers_v1"] == false
    }

    private func commitCustomModel() {
        Self.commitCustomModel(customModelText, into: &draft)
        resetCustomSizeEditor()
    }

    /// Writes a typed model name into the draft once: trimmed, never empty,
    /// and only when it differs, so a committed value causes at most one push
    /// and an unchanged or blank one causes none. Returns whether it changed.
    @discardableResult
    static func commitCustomModel(_ text: String, into draft: inout AppSettings) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != draft.imageGenerationModel else { return false }
        selectModel(name, into: &draft)
        return true
    }

    static func selectModel(_ name: String, into draft: inout AppSettings) {
        // Commit one consistent preference update when changing families.
        if !ImageGenerationOptions.qualities(for: name).contains(where: { $0.rawValue == draft.imageGenerationQuality }) {
            draft.imageGenerationQuality = "auto"
        }
        if !ImageGenerationOptions.isValidSize(draft.imageGenerationSize, model: name) {
            draft.imageGenerationSize = "auto"
        }
        draft.imageGenerationModel = name
    }

    @discardableResult
    static func commitCustomSize(_ text: String, into draft: inout AppSettings) -> Bool {
        let size = text.lowercased().replacingOccurrences(of: "×", with: "x")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard ImageGenerationOptions.isValidSize(size, model: draft.imageGenerationModel) else { return false }
        draft.imageGenerationSize = size
        return true
    }

    private func commitCustomSize() {
        customSizeError = Self.commitCustomSize(customSizeText, into: &draft)
            ? nil : "Enter valid image dimensions, such as 1536x864. Your previous size is still selected."
    }

    private func resetCustomSizeEditor() {
        customSizeSelected = !ImageGenerationOptions.sizes(for: draft.imageGenerationModel)
            .contains(where: { $0.rawValue == draft.imageGenerationSize })
        customSizeText = draft.imageGenerationSize == "auto" ? "" : draft.imageGenerationSize
        customSizeError = nil
    }

    private var sizeSelection: Binding<String> {
        Binding(get: { customSizeSelected ? Self.customSizeTag : draft.imageGenerationSize }, set: { value in
            customSizeError = nil
            customSizeSelected = value == Self.customSizeTag
            if customSizeSelected {
                customSizeText = draft.imageGenerationSize == "auto" ? "" : draft.imageGenerationSize
            } else {
                draft.imageGenerationSize = value
            }
        })
    }

    private var eligibleAccounts: [ProviderAccount] {
        // Read through the accounts model so the picker refreshes as accounts
        // are added or removed while this page is open.
        providerAccounts.providerAccounts.filter { account in
            account.kind.supportsImageGeneration
                && account.isCredentialReady(in: model.credentialStore)
                && (account.kind == .chatGPT
                    || !account.resolvedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var isChatGPTSelected: Bool {
        eligibleAccounts.first { $0.id.uuidString == draft.imageGenerationAccountID }?.kind == .chatGPT
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
                    Self.selectModel(newValue, into: &draft)
                    resetCustomSizeEditor()
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
