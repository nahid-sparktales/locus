import AppKit
import SwiftUI

/// The character chapter of Getting Started, hosted by its existing sheet.
/// Draft edits stay local; only the two final actions commit a canonical profile.
struct CompanionSetupView: View {
    var availableSize = CGSize(width: 760, height: 720)
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var onboarding: OnboardingModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var runtime: RuntimeStatusModel
    @EnvironmentObject private var accounts: ProviderAccountsModel
    @Environment(\.locusViewColors) private var colors
    @State private var customCharacterPresented = false
    @State private var characterCollection: CharacterCollection = .characters
    @FocusState private var nameFocused: Bool

    private enum CharacterCollection: String, CaseIterable, Identifiable {
        case characters = "Characters", originals = "Originals"
        var id: String { rawValue }
    }

    private var draft: CompanionOnboardingDraft { onboarding.companion.draft }
    private var existingProfile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == draft.existingProfileID }
    }
    private var displayName: String { existingProfile?.name ?? draft.name }
    private var appearance: CompanionAppearance {
        guard let existingProfile else { return draft.appearance }
        return agentTeams.agentAppearances[existingProfile.id]
            ?? (agentTeams.agentAvatarData[existingProfile.id] == nil ? .robot : .portrait)
    }
    private var imageData: Data? {
        if let existingProfile { return agentTeams.agentAvatarData[existingProfile.id] }
        return draft.avatarData
    }
    private var title: String {
        switch onboarding.companion.step {
        case .welcome: "Meet your Locus companion"
        case .appearance: "A face that feels like yours"
        case .name: "What should we call your companion?"
        case .introduction: "This is \(displayName)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your companion").font(.locus(size: 13, weight: .semibold))
                Spacer()
                Text("Locus").foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, 28).padding(.top, 22)
            ScrollView {
                VStack(spacing: 22) {
                    Text(title)
                        .font(.locus(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("companion.title")
                    switch onboarding.companion.step {
                    case .welcome: welcome
                    case .appearance: chooseAppearance
                    case .name: naming
                    case .introduction: introduction
                    }
                    if let error = onboarding.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(colors.warning)
                            .accessibilityIdentifier("companion.error")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            Divider()
            footer.padding(22)
        }
        .font(.locus(size: 13))
        .foregroundStyle(colors.ink)
        .background(colors.paper)
        .frame(width: min(680, max(520, availableSize.width - 60)),
               height: min(620, max(500, availableSize.height - 40)))
        .locusSheet(isPresented: $customCharacterPresented) {
            CompanionCustomCharacterPicker { data in
                onboarding.selectExistingCompanion(nil)
                onboarding.selectCompanionAppearance(.portrait, avatarData: data)
            }
            .appFeatureEnvironment(from: model)
        }
        .onChange(of: onboarding.companion.step) { _, step in nameFocused = step == .name }
        .onAppear {
            nameFocused = onboarding.companion.step == .name
            characterCollection = appearance.kind == .builtIn ? .originals : .characters
            onboarding.refreshReadiness()
        }
        .onChange(of: appearance.kind) { _, kind in
            if kind == .builtIn { characterCollection = .originals }
            else if kind == .bundledSprite { characterCollection = .characters }
        }
        .onReceive(runtime.objectWillChange) { _ in
            Task { @MainActor in onboarding.refreshReadiness() }
        }
        .onReceive(accounts.objectWillChange) { _ in
            Task { @MainActor in onboarding.refreshReadiness() }
        }
    }

    private func preview(size: CGFloat = 180) -> some View {
        CompanionCharacterView(appearance: appearance, size: size, pose: .greeting,
            animationsEnabled: agentTeams.companionAnimationsEnabled, customImageData: imageData)
            .id(appearance)
            .accessibilityLabel("\(displayName.isEmpty ? "Your companion" : displayName), \(appearance.displayName)")
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            preview(size: 200)
            Text("A familiar face for your ideas, projects, and everyday work.")
                .font(.locus(size: 16)).multilineTextAlignment(.center)
                .foregroundStyle(colors.textSecondary)
            Text("Choose a character and a name. Your companion is the agent you’ll work with in Locus.")
                .multilineTextAlignment(.center).foregroundStyle(colors.textSecondary)
            if !agentTeams.agentProfiles.isEmpty {
                existingAgentPicker
            }
        }
    }

    private var existingAgentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Companion identity", selection: Binding(
                get: { draft.existingProfileID },
                set: { onboarding.selectExistingCompanion($0) }
            )) {
                Text("Create a new companion").tag(UUID?.none)
                ForEach(agentTeams.agentProfiles) { profile in
                    Text("Use \(profile.name)").tag(Optional(profile.id))
                }
            }
            .accessibilityIdentifier("companion.existingAgent")
            if existingProfile != nil {
                Text("This links the saved agent with its current name, picture, conversations, and settings. You can edit it from its profile later.")
                    .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
            }
        }
        .padding(16).background(colors.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var chooseAppearance: some View {
        VStack(spacing: 18) {
            if existingProfile != nil {
                preview()
                existingAgentPicker
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) { preview(); gallery }
                    VStack(spacing: 12) { preview(size: 150); gallery }
                }
                HStack(spacing: 12) {
                    Button("Surprise me") {
                        onboarding.selectCompanionAppearance(.surprise(seed: UInt64.random(in: .min ... .max)))
                    }
                    .accessibilityIdentifier("companion.surprise")
                    Button("Create your own…") { customCharacterPresented = true }
                        .accessibilityIdentifier("companion.createOwn")
                }
                Text("Bundled characters and Surprise me work offline. Create your own also offers image import.")
                    .font(.locus(size: 11)).foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
                if appearance.supportsAppearanceControls {
                    HStack(spacing: 20) {
                        Picker("Accent", selection: Binding(get: { appearance.palette }, set: { palette in
                            var value = appearance; value.palette = palette
                            onboarding.selectCompanionAppearance(value)
                        })) {
                            ForEach(CompanionPalette.allCases) { Text($0.name).tag($0) }
                        }
                        .accessibilityIdentifier("companion.palette")
                        Picker("Accessory", selection: Binding(get: { appearance.accessory }, set: { accessory in
                            var value = appearance; value.accessory = accessory
                            onboarding.selectCompanionAppearance(value)
                        })) {
                            ForEach(CompanionAccessory.allCases) { Text($0.name).tag($0) }
                        }
                        .accessibilityIdentifier("companion.accessory")
                    }
                }
            }
            Toggle("Animate characters", isOn: Binding(get: { agentTeams.companionAnimationsEnabled },
                set: { agentTeams.setCompanionAnimationsEnabled($0) }))
                .toggleStyle(.checkbox).font(.locus(size: 12))
                .accessibilityIdentifier("companion.animations")
        }
    }

    private var gallery: some View {
        VStack(spacing: 12) {
            Picker("Character collection", selection: $characterCollection) {
                ForEach(CharacterCollection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("companion.collection")
            LazyVGrid(columns: [GridItem(.fixed(86)), GridItem(.fixed(86)), GridItem(.fixed(86))], spacing: 10) {
                if characterCollection == .characters {
                    ForEach(CompanionBundledSprite.allCases) { sprite in
                        characterButton(appearance: .init(sprite: sprite), title: sprite.displayName,
                            selected: appearance.bundledSprite == sprite,
                            identifier: "companion.sprite.\(sprite.id)",
                            hint: sprite.detail) {
                            onboarding.selectCompanionAppearance(.init(sprite: sprite))
                        }
                    }
                } else {
                    ForEach(CompanionCharacterKind.allCases) { character in
                        characterButton(appearance: .init(character: character, palette: appearance.palette),
                            title: character.name, selected: appearance.builtIn == character,
                            identifier: "companion.character.\(character.rawValue)", hint: character.detail) {
                            onboarding.selectCompanionAppearance(CompanionAppearance(character: character,
                                palette: appearance.palette, accessory: appearance.accessory))
                        }
                    }
                }
            }
        }
        .frame(width: 278)
    }

    private func characterButton(appearance: CompanionAppearance, title: String, selected: Bool,
                                 identifier: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                CompanionCharacterView(appearance: appearance, size: 62, animationsEnabled: false)
                Text(title).font(.locus(size: 11, weight: .medium))
            }
            .frame(width: 82, height: 88)
            .background(selected ? colors.signalDeep.opacity(0.12) : colors.white,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? colors.signalDeep : colors.line, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .help(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var naming: some View {
        VStack(spacing: 18) {
            preview(size: 180)
            TextField("Name", text: Binding(get: { draft.name }, set: { onboarding.setCompanionName($0) }))
                .textFieldStyle(.roundedBorder).font(.locus(size: 20))
                .multilineTextAlignment(.center).frame(maxWidth: 320)
                .focused($nameFocused).accessibilityIdentifier("companion.name")
                .onSubmit { if onboarding.companionNameError == nil { onboarding.companionNext() } }
            if let error = onboarding.companionNameError {
                Text(error).foregroundStyle(colors.warning).font(.locus(size: 12))
            } else {
                Text("You can change this anytime from your companion’s profile.")
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            preview(size: 200)
            Text("Hi, I’m \(displayName). What would you like to work on first?")
                .font(.locus(size: 20, weight: .medium)).multilineTextAlignment(.center)
                .accessibilityIdentifier("companion.introduction")
            if !onboarding.readiness.ready {
                Text("Your companion is ready. Connect a model to start chatting.")
                    .foregroundStyle(colors.textSecondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("companion.connectNotice")
            }
            Text("This introduction is a preview. Saving your companion doesn’t send a message or start any work.")
                .font(.locus(size: 11)).foregroundStyle(colors.textSecondary).multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if onboarding.companion.step == .welcome {
                Button("Not now") { onboarding.dismiss() }
                    .accessibilityIdentifier("onboarding.skip")
            } else {
                Button("Back") { onboarding.companionBack() }
                    .accessibilityIdentifier("companion.back")
                if onboarding.companion.step != .introduction {
                    Button("Not now") { onboarding.dismiss() }.accessibilityIdentifier("onboarding.skip")
                }
            }
            Spacer()
            if onboarding.companion.step == .introduction {
                Button("Explore Locus") { model.finishCompanionSetup(startChat: false) }
                    .accessibilityIdentifier("companion.explore")
                Button("Start with \(displayName)") { model.finishCompanionSetup(startChat: true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("companion.start")
            } else {
                Button(onboarding.companion.step == .welcome ? "Make it yours" : "Continue") {
                    onboarding.companionNext()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(onboarding.companion.step == .name && onboarding.companionNameError != nil)
                .accessibilityIdentifier("companion.continue")
            }
        }
    }
}
